// mirror_native.c — Boox Mirror native renderer.
//
// Receives LZ4+delta compressed RGB frames over TCP,
// decompresses, applies delta, and renders via GL or ANativeWindow.
// Entire hot path is C — no JNI calls, no Java GC.
//
// Protocol: [0xDA 0x7E] [flags:1B] [seq:4B LE] [length:4B LE] [LZ4 payload]
//   flags bit 0: 1=keyframe, 0=delta (XOR with previous)
// ACK:      [0xDA 0x7A] [seq:4B LE] — sent back after rendering each frame

#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <arm_neon.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <android/hardware_buffer.h>
#include "lz4.h"

#ifndef AHARDWAREBUFFER_FORMAT_R8_UNORM
#define AHARDWAREBUFFER_FORMAT_R8_UNORM 0x38
#endif

#define TAG "DaylightMirror"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// Default resolution (updated dynamically via CMD_RESOLUTION from server)
#define DEFAULT_FRAME_W 1024
#define DEFAULT_FRAME_H 768

#define MAGIC_FRAME_0 0xDA
#define MAGIC_FRAME_1 0x7E
#define MAGIC_CMD_1   0x7F
#define MAGIC_ACK_1   0x7A
#define FLAG_KEYFRAME 0x01
#define FRAME_HEADER_SIZE 11
#define CMD_BRIGHTNESS 0x01
#define CMD_WARMTH     0x02
#define CMD_RESOLUTION 0x04
#define CMD_COLOR_MODE 0x05
#define CMD_REFRESH    0x06
#define FLAG_TILED     0x02
#define MAGIC_TOUCH_1  0x7B

// Global state
static ANativeWindow *g_window = NULL;
static pthread_t g_decode_thread;
static pthread_t g_render_thread;
static volatile int g_running = 0;
static JavaVM *g_jvm = NULL;
static jobject g_activity = NULL;
static char g_host[64] = "127.0.0.1";
static int g_port = 8888;
static int g_sock = -1;

// Color mode: 0=greyscale (1 byte/pixel), 1=RGB (3 bytes/pixel)
static volatile int g_color_mode = 0;
static int g_bytes_per_pixel = 1;

// Dynamic frame dimensions (set by CMD_RESOLUTION before first frame)
static uint32_t g_frame_w = DEFAULT_FRAME_W;
static uint32_t g_frame_h = DEFAULT_FRAME_H;
static uint32_t g_pixel_count = DEFAULT_FRAME_W * DEFAULT_FRAME_H;
static uint32_t g_buffer_size = DEFAULT_FRAME_W * DEFAULT_FRAME_H * 1;  // grey: 1 byte/pixel default
static uint32_t g_max_compressed = DEFAULT_FRAME_W * DEFAULT_FRAME_H * 1 + 256;

// Frame buffers (allocated once, reused — reallocated on resolution change)
static uint8_t *g_current_frame = NULL;   // Decompressed RGB pixels
static uint8_t *g_compressed_buf = NULL;  // Incoming compressed data

static pthread_mutex_t g_frame_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_frame_cond = PTHREAD_COND_INITIALIZER;
static uint8_t *g_render_frames[2] = {NULL, NULL};
static int g_ready_index = 0;
static int g_has_ready_frame = 0;
static uint32_t g_ready_seq = 0;
static int g_overwritten_frames = 0;
static double g_render_neon_sum = 0.0;
static double g_render_vsync_sum = 0.0;
static int g_render_stat_frames = 0;

static EGLDisplay g_egl_display = EGL_NO_DISPLAY;
static EGLSurface g_egl_surface = EGL_NO_SURFACE;
static EGLContext g_egl_context = EGL_NO_CONTEXT;
static GLuint g_gl_program = 0;
static GLuint g_gl_texture = 0;
static GLuint g_gl_vbo = 0;
static GLint g_gl_attr_position = -1;
static GLint g_gl_attr_texcoord = -1;
static GLint g_gl_uniform_texture = -1;
static uint32_t g_gl_tex_w = 0;
static uint32_t g_gl_tex_h = 0;
static int g_gl_ready = 0;

static const char *k_vertex_shader_src =
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texcoord;\n"
    "varying vec2 v_texcoord;\n"
    "void main() {\n"
    "    gl_Position = a_position;\n"
    "    v_texcoord = a_texcoord;\n"
    "}\n";

// RGB fragment shader — samples .rgb directly
static const char *k_fragment_shader_rgb =
    "precision mediump float;\n"
    "varying vec2 v_texcoord;\n"
    "uniform sampler2D u_texture;\n"
    "void main() {\n"
    "    vec3 color = texture2D(u_texture, v_texcoord).rgb;\n"
    "    gl_FragColor = vec4(color, 1.0);\n"
    "}\n";

// Greyscale fragment shader — samples .r (luminance), expands to RGB
static const char *k_fragment_shader_grey =
    "precision mediump float;\n"
    "varying vec2 v_texcoord;\n"
    "uniform sampler2D u_texture;\n"
    "void main() {\n"
    "    float lum = texture2D(u_texture, v_texcoord).r;\n"
    "    gl_FragColor = vec4(lum, lum, lum, 1.0);\n"
    "}\n";

// Active fragment shader — set by color mode
static int g_gl_color_mode = -1;  // track which mode the GL program was built for

static void gl_teardown(void);

static GLuint gl_compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    if (!shader) {
        LOGE("glCreateShader failed: %u", (unsigned)type);
        return 0;
    }

    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);

    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        char info_log[512];
        GLsizei log_len = 0;
        glGetShaderInfoLog(shader, sizeof(info_log), &log_len, info_log);
        LOGE("Shader compile failed: %s", info_log);
        glDeleteShader(shader);
        return 0;
    }

    return shader;
}

static int gl_create_program(void) {
    const char *frag_src = g_color_mode ? k_fragment_shader_rgb : k_fragment_shader_grey;
    GLuint vertex_shader = gl_compile_shader(GL_VERTEX_SHADER, k_vertex_shader_src);
    GLuint fragment_shader = gl_compile_shader(GL_FRAGMENT_SHADER, frag_src);
    if (!vertex_shader || !fragment_shader) {
        if (vertex_shader) glDeleteShader(vertex_shader);
        if (fragment_shader) glDeleteShader(fragment_shader);
        return 0;
    }

    g_gl_program = glCreateProgram();
    if (!g_gl_program) {
        LOGE("glCreateProgram failed");
        glDeleteShader(vertex_shader);
        glDeleteShader(fragment_shader);
        return 0;
    }

    glAttachShader(g_gl_program, vertex_shader);
    glAttachShader(g_gl_program, fragment_shader);
    glLinkProgram(g_gl_program);

    GLint linked = GL_FALSE;
    glGetProgramiv(g_gl_program, GL_LINK_STATUS, &linked);
    glDeleteShader(vertex_shader);
    glDeleteShader(fragment_shader);

    if (linked != GL_TRUE) {
        char info_log[512];
        GLsizei log_len = 0;
        glGetProgramInfoLog(g_gl_program, sizeof(info_log), &log_len, info_log);
        LOGE("Program link failed: %s", info_log);
        glDeleteProgram(g_gl_program);
        g_gl_program = 0;
        return 0;
    }

    g_gl_attr_position = glGetAttribLocation(g_gl_program, "a_position");
    g_gl_attr_texcoord = glGetAttribLocation(g_gl_program, "a_texcoord");
    g_gl_uniform_texture = glGetUniformLocation(g_gl_program, "u_texture");
    if (g_gl_attr_position < 0 || g_gl_attr_texcoord < 0 || g_gl_uniform_texture < 0) {
        LOGE("GL attribute/uniform lookup failed");
        return 0;
    }

    g_gl_color_mode = g_color_mode;
    return 1;
}

static int gl_create_texture(uint32_t width, uint32_t height) {
    if (g_gl_texture) {
        glDeleteTextures(1, &g_gl_texture);
        g_gl_texture = 0;
    }

    glGenTextures(1, &g_gl_texture);
    if (!g_gl_texture) {
        LOGE("glGenTextures failed");
        return 0;
    }

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, g_gl_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    GLenum tex_format = g_color_mode ? GL_RGB : GL_LUMINANCE;
    glTexImage2D(GL_TEXTURE_2D, 0, (GLint)tex_format, (GLsizei)width, (GLsizei)height,
                 0, tex_format, GL_UNSIGNED_BYTE, NULL);

    if (glGetError() != GL_NO_ERROR) {
        LOGE("glTexImage2D failed for %ux%u (format=%s)", width, height, g_color_mode ? "RGB" : "LUMINANCE");
        glDeleteTextures(1, &g_gl_texture);
        g_gl_texture = 0;
        return 0;
    }

    g_gl_tex_w = width;
    g_gl_tex_h = height;
    return 1;
}

static int gl_init(ANativeWindow *window) {
    if (!window) return 0;
    if (g_gl_ready) return 1;

    const EGLint config_attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    const EGLint context_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    static const GLfloat quad_vertices[] = {
        -1.0f, -1.0f, 0.0f, 1.0f,
         1.0f, -1.0f, 1.0f, 1.0f,
        -1.0f,  1.0f, 0.0f, 0.0f,
        -1.0f,  1.0f, 0.0f, 0.0f,
         1.0f, -1.0f, 1.0f, 1.0f,
         1.0f,  1.0f, 1.0f, 0.0f,
    };

    g_egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_egl_display == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay failed");
        goto fail;
    }

    if (!eglInitialize(g_egl_display, NULL, NULL)) {
        LOGE("eglInitialize failed: 0x%x", eglGetError());
        goto fail;
    }

    EGLConfig config;
    EGLint num_configs = 0;
    if (!eglChooseConfig(g_egl_display, config_attribs, &config, 1, &num_configs) || num_configs < 1) {
        LOGE("eglChooseConfig failed: 0x%x", eglGetError());
        goto fail;
    }

    g_egl_surface = eglCreateWindowSurface(g_egl_display, config, window, NULL);
    if (g_egl_surface == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface failed: 0x%x", eglGetError());
        goto fail;
    }

    g_egl_context = eglCreateContext(g_egl_display, config, EGL_NO_CONTEXT, context_attribs);
    if (g_egl_context == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext failed: 0x%x", eglGetError());
        goto fail;
    }

    if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
        LOGE("eglMakeCurrent failed: 0x%x", eglGetError());
        goto fail;
    }

    eglSwapInterval(g_egl_display, 0);

    if (!gl_create_program()) goto fail;

    glUseProgram(g_gl_program);
    glUniform1i(g_gl_uniform_texture, 0);

    glGenBuffers(1, &g_gl_vbo);
    if (!g_gl_vbo) {
        LOGE("glGenBuffers failed");
        goto fail;
    }
    glBindBuffer(GL_ARRAY_BUFFER, g_gl_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad_vertices), quad_vertices, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    if (!gl_create_texture(g_frame_w, g_frame_h)) goto fail;

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    g_gl_ready = 1;
    return 1;

fail:
    gl_teardown();
    return 0;
}

static int gl_ensure_texture_size(uint32_t width, uint32_t height) {
    if (!g_gl_ready) return 0;
    // Rebuild program + texture if color mode changed
    if (g_gl_color_mode != g_color_mode) {
        if (g_gl_program) { glDeleteProgram(g_gl_program); g_gl_program = 0; }
        if (!gl_create_program()) return 0;
        glUseProgram(g_gl_program);
        glUniform1i(g_gl_uniform_texture, 0);
        // Force texture recreation with new format
        g_gl_tex_w = 0; g_gl_tex_h = 0;
    }
    if (g_gl_texture && g_gl_tex_w == width && g_gl_tex_h == height) return 1;
    return gl_create_texture(width, height);
}

static void gl_teardown(void) {
    if (g_egl_display != EGL_NO_DISPLAY && g_egl_surface != EGL_NO_SURFACE && g_egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context);
        if (g_gl_texture) {
            glDeleteTextures(1, &g_gl_texture);
            g_gl_texture = 0;
        }
        if (g_gl_vbo) {
            glDeleteBuffers(1, &g_gl_vbo);
            g_gl_vbo = 0;
        }
        if (g_gl_program) {
            glDeleteProgram(g_gl_program);
            g_gl_program = 0;
        }
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    } else {
        g_gl_texture = 0;
        g_gl_vbo = 0;
        g_gl_program = 0;
    }

    if (g_egl_display != EGL_NO_DISPLAY) {
        if (g_egl_context != EGL_NO_CONTEXT) {
            eglDestroyContext(g_egl_display, g_egl_context);
        }
        if (g_egl_surface != EGL_NO_SURFACE) {
            eglDestroySurface(g_egl_display, g_egl_surface);
        }
        eglTerminate(g_egl_display);
    }

    g_egl_display = EGL_NO_DISPLAY;
    g_egl_surface = EGL_NO_SURFACE;
    g_egl_context = EGL_NO_CONTEXT;
    g_gl_attr_position = -1;
    g_gl_attr_texcoord = -1;
    g_gl_uniform_texture = -1;
    g_gl_tex_w = 0;
    g_gl_tex_h = 0;
    g_gl_ready = 0;
}

// Read exactly n bytes from socket (handles partial reads)
static int read_exact(int sock, void *buf, int n) {
    int total = 0;
    while (total < n) {
        int r = recv(sock, (uint8_t *)buf + total, n - total, 0);
        if (r <= 0) return -1;
        total += r;
    }
    return total;
}

static void apply_delta_neon(uint8_t *frame, const uint8_t *delta, int count) {
    int i = 0;
    for (; i + 64 <= count; i += 64) {
        __builtin_prefetch(frame + i + 64, 1, 1);
        __builtin_prefetch(delta + i + 64, 0, 1);
        uint8x16_t f0 = vld1q_u8(frame + i);
        uint8x16_t f1 = vld1q_u8(frame + i + 16);
        uint8x16_t f2 = vld1q_u8(frame + i + 32);
        uint8x16_t f3 = vld1q_u8(frame + i + 48);
        uint8x16_t d0 = vld1q_u8(delta + i);
        uint8x16_t d1 = vld1q_u8(delta + i + 16);
        uint8x16_t d2 = vld1q_u8(delta + i + 32);
        uint8x16_t d3 = vld1q_u8(delta + i + 48);
        vst1q_u8(frame + i, veorq_u8(f0, d0));
        vst1q_u8(frame + i + 16, veorq_u8(f1, d1));
        vst1q_u8(frame + i + 32, veorq_u8(f2, d2));
        vst1q_u8(frame + i + 48, veorq_u8(f3, d3));
    }

    for (; i + 16 <= count; i += 16) {
        uint8x16_t f = vld1q_u8(frame + i);
        uint8x16_t d = vld1q_u8(delta + i);
        vst1q_u8(frame + i, veorq_u8(f, d));
    }
    // Remaining bytes
    for (; i < count; i++) {
        frame[i] ^= delta[i];
    }
}

// Write greyscale pixels to ANativeWindow with NEON grey→RGBX expansion (1 byte → 4 bytes per pixel).
static void blit_grey_to_surface(ANativeWindow *window, const uint8_t *grey) {
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) {
        LOGE("ANativeWindow_lock failed");
        return;
    }

    uint8_t *dst = (uint8_t *)buffer.bits;
    int fw = (int)g_frame_w;
    int fh = (int)g_frame_h;
    int dst_stride = buffer.stride * 4;

    for (int y = 0; y < fh && y < buffer.height; y++) {
        uint8_t *row = dst + y * dst_stride;
        const uint8_t *src = grey + y * fw;
        int x = 0;
        // NEON: process 16 pixels at a time (16 grey bytes → 64 RGBX bytes)
        for (; x + 16 <= fw && x + 16 <= buffer.width; x += 16) {
            uint8x16_t g = vld1q_u8(src + x);
            uint8x16_t ff = vdupq_n_u8(0xFF);
            uint8x16x4_t rgbx;
            rgbx.val[0] = g;   // R = grey
            rgbx.val[1] = g;   // G = grey
            rgbx.val[2] = g;   // B = grey
            rgbx.val[3] = ff;  // X = 0xFF
            vst4q_u8(row + x * 4, rgbx);
        }
        for (; x < fw && x < buffer.width; x++) {
            uint8_t v = src[x];
            row[x * 4 + 0] = v;     // R
            row[x * 4 + 1] = v;     // G
            row[x * 4 + 2] = v;     // B
            row[x * 4 + 3] = 0xFF;  // X
        }
    }

    ANativeWindow_unlockAndPost(window);
}

// Write RGB pixels to ANativeWindow with RGBX expansion (3 bytes → 4 bytes per pixel).
static void blit_rgb_to_surface(ANativeWindow *window, const uint8_t *rgb) {
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) {
        LOGE("ANativeWindow_lock failed");
        return;
    }

    uint8_t *dst = (uint8_t *)buffer.bits;
    int fw = (int)g_frame_w;
    int fh = (int)g_frame_h;

    // RGBX_8888 (4 bytes per pixel) — expand RGB→RGBX with NEON
    int dst_stride = buffer.stride * 4;
    for (int y = 0; y < fh && y < buffer.height; y++) {
        uint8_t *row = dst + y * dst_stride;
        const uint8_t *src = rgb + y * fw * 3;
        int x = 0;
        // NEON: process 16 pixels at a time (48 RGB bytes → 64 RGBX bytes)
        for (; x + 16 <= fw && x + 16 <= buffer.width; x += 16) {
            uint8x16x3_t in_rgb = vld3q_u8(src + x * 3);
            uint8x16_t ff = vdupq_n_u8(0xFF);
            uint8x16x4_t rgbx;
            rgbx.val[0] = in_rgb.val[0];  // R
            rgbx.val[1] = in_rgb.val[1];  // G
            rgbx.val[2] = in_rgb.val[2];  // B
            rgbx.val[3] = ff;             // X
            vst4q_u8(row + x * 4, rgbx);
        }
        for (; x < fw && x < buffer.width; x++) {
            row[x * 4 + 0] = src[x * 3 + 0];  // R
            row[x * 4 + 1] = src[x * 3 + 1];  // G
            row[x * 4 + 2] = src[x * 3 + 2];  // B
            row[x * 4 + 3] = 0xFF;             // X
        }
    }

    ANativeWindow_unlockAndPost(window);
}

// Send touch event to Mac: [DA 7B] [action:1] [xNorm:2 LE] [yNorm:2 LE]
static void send_touch_event(int action, int x_norm, int y_norm) {
    int sock = g_sock;
    if (sock < 0) return;
    uint8_t packet[7];
    packet[0] = MAGIC_FRAME_0;   // 0xDA
    packet[1] = MAGIC_TOUCH_1;   // 0x7B
    packet[2] = (uint8_t)action;
    packet[3] = (uint8_t)(x_norm & 0xFF);
    packet[4] = (uint8_t)((x_norm >> 8) & 0xFF);
    packet[5] = (uint8_t)(y_norm & 0xFF);
    packet[6] = (uint8_t)((y_norm >> 8) & 0xFF);
    send(sock, packet, 7, MSG_NOSIGNAL);
}

// Send scroll event to Mac: [DA 7B] [3] [xNorm:2 LE] [yNorm:2 LE] [deltaY:2 LE signed]
static void send_scroll_event(int x_norm, int y_norm, int delta_y) {
    int sock = g_sock;
    if (sock < 0) return;
    uint8_t packet[9];
    packet[0] = MAGIC_FRAME_0;
    packet[1] = MAGIC_TOUCH_1;
    packet[2] = 3;  // ACTION_SCROLL
    packet[3] = (uint8_t)(x_norm & 0xFF);
    packet[4] = (uint8_t)((x_norm >> 8) & 0xFF);
    packet[5] = (uint8_t)(y_norm & 0xFF);
    packet[6] = (uint8_t)((y_norm >> 8) & 0xFF);
    int16_t dy = (int16_t)delta_y;
    packet[7] = (uint8_t)(dy & 0xFF);
    packet[8] = (uint8_t)((dy >> 8) & 0xFF);
    send(sock, packet, 9, MSG_NOSIGNAL);
}

static void send_ack(int sock, uint32_t seq) {
    uint8_t ack[6];
    ack[0] = MAGIC_FRAME_0;
    ack[1] = MAGIC_ACK_1;
    ack[2] = (uint8_t)(seq & 0xFF);
    ack[3] = (uint8_t)((seq >> 8) & 0xFF);
    ack[4] = (uint8_t)((seq >> 16) & 0xFF);
    ack[5] = (uint8_t)((seq >> 24) & 0xFF);
    send(sock, ack, 6, MSG_NOSIGNAL);
}

static double ms_diff(struct timespec a, struct timespec b) {
    return ((b.tv_sec - a.tv_sec) * 1000.0) + ((b.tv_nsec - a.tv_nsec) / 1e6);
}

static void notify_connection_state(int connected) {
    if (!g_jvm || !g_activity) return;
    JNIEnv *env;
    int attached = 0;
    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
        attached = 1;
    }
    jclass cls = (*env)->GetObjectClass(env, g_activity);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onConnectionState", "(Z)V");
    if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jboolean)(connected ? 1 : 0));
    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
}

static void publish_frame(const uint8_t *frame, uint32_t seq) {
    if (!frame) return;
    pthread_mutex_lock(&g_frame_mutex);

    const int write_index = (g_ready_index == 0) ? 1 : 0;
    if (g_render_frames[write_index]) {
        memcpy(g_render_frames[write_index], frame, g_buffer_size);
        if (g_has_ready_frame) g_overwritten_frames += 1;
        g_ready_index = write_index;
        g_ready_seq = seq;
        g_has_ready_frame = 1;
        pthread_cond_signal(&g_frame_cond);
    }
    pthread_mutex_unlock(&g_frame_mutex);
}

static int reallocate_buffers(uint32_t new_w, uint32_t new_h, uint8_t **decompress_buf) {
    uint32_t new_pixels = new_w * new_h;
    uint32_t new_buf_size = new_pixels * g_bytes_per_pixel;
    uint32_t new_max_compressed = new_buf_size + 256;

    uint8_t *new_current = (uint8_t *)calloc(new_buf_size, 1);
    uint8_t *new_compressed = (uint8_t *)malloc(new_max_compressed);
    uint8_t *new_decompress = (uint8_t *)malloc(new_buf_size);
    uint8_t *new_render0 = (uint8_t *)malloc(new_buf_size);
    uint8_t *new_render1 = (uint8_t *)malloc(new_buf_size);

    if (!new_current || !new_compressed || !new_decompress || !new_render0 || !new_render1) {
        free(new_current);
        free(new_compressed);
        free(new_decompress);
        free(new_render0);
        free(new_render1);
        return 0;
    }

    pthread_mutex_lock(&g_frame_mutex);
    free(g_current_frame);
    free(g_compressed_buf);
    free(*decompress_buf);
    free(g_render_frames[0]);
    free(g_render_frames[1]);

    g_current_frame = new_current;
    g_compressed_buf = new_compressed;
    *decompress_buf = new_decompress;
    g_render_frames[0] = new_render0;
    g_render_frames[1] = new_render1;
    memset(g_render_frames[0], 0xFF, new_buf_size);
    memset(g_render_frames[1], 0xFF, new_buf_size);
    g_ready_index = 0;
    g_has_ready_frame = 0;

    g_frame_w = new_w;
    g_frame_h = new_h;
    g_pixel_count = new_pixels;
    g_buffer_size = new_buf_size;
    g_max_compressed = new_max_compressed;
    pthread_mutex_unlock(&g_frame_mutex);
    return 1;
}

static void *render_thread(void *arg) {
    (void)arg;
    uint8_t *render_local = NULL;
    uint32_t render_capacity = 0;
    uint32_t render_w = 0;
    uint32_t render_h = 0;
    int gl_disabled = 0;

    while (g_running) {
        pthread_mutex_lock(&g_frame_mutex);
        while (g_running && !g_has_ready_frame) {
            pthread_cond_wait(&g_frame_cond, &g_frame_mutex);
        }
        if (!g_running) {
            pthread_mutex_unlock(&g_frame_mutex);
            break;
        }

        const int frame_index = g_ready_index;
        uint32_t local_buf_size = g_buffer_size;
        render_w = g_frame_w;
        render_h = g_frame_h;

        if (local_buf_size > render_capacity) {
            uint8_t *resized = (uint8_t *)realloc(render_local, local_buf_size);
            if (!resized) {
                g_has_ready_frame = 0;
                pthread_mutex_unlock(&g_frame_mutex);
                continue;
            }
            render_local = resized;
            render_capacity = local_buf_size;
        }

        memcpy(render_local, g_render_frames[frame_index], local_buf_size);
        g_has_ready_frame = 0;
        pthread_mutex_unlock(&g_frame_mutex);

        struct timespec t4a, t4b, t5;
        if (g_window && render_local) {
            int did_present = 0;

            if (!gl_disabled) {
                if (!g_gl_ready && !gl_init(g_window)) {
                    LOGE("GL init failed, falling back to CPU blit");
                    gl_disabled = 1;
                }

                if (g_gl_ready && !gl_ensure_texture_size(render_w, render_h)) {
                    LOGE("GL texture resize failed for %ux%u", render_w, render_h);
                    gl_teardown();
                    gl_disabled = 1;
                }

                if (g_gl_ready) {
                    EGLint surface_w = 0;
                    EGLint surface_h = 0;
                    eglQuerySurface(g_egl_display, g_egl_surface, EGL_WIDTH, &surface_w);
                    eglQuerySurface(g_egl_display, g_egl_surface, EGL_HEIGHT, &surface_h);
                    if (surface_w > 0 && surface_h > 0) {
                        glViewport(0, 0, surface_w, surface_h);
                    }

                    glUseProgram(g_gl_program);
                    glActiveTexture(GL_TEXTURE0);
                    glBindTexture(GL_TEXTURE_2D, g_gl_texture);
                    glBindBuffer(GL_ARRAY_BUFFER, g_gl_vbo);
                    glEnableVertexAttribArray((GLuint)g_gl_attr_position);
                    glEnableVertexAttribArray((GLuint)g_gl_attr_texcoord);
                    glVertexAttribPointer((GLuint)g_gl_attr_position, 2, GL_FLOAT, GL_FALSE,
                                          4 * sizeof(GLfloat), (const void *)0);
                    glVertexAttribPointer((GLuint)g_gl_attr_texcoord, 2, GL_FLOAT, GL_FALSE,
                                          4 * sizeof(GLfloat), (const void *)(2 * sizeof(GLfloat)));

                    clock_gettime(CLOCK_MONOTONIC, &t4a);
                    GLenum upload_format = g_color_mode ? GL_RGB : GL_LUMINANCE;
                    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                                    (GLsizei)render_w, (GLsizei)render_h,
                                    upload_format, GL_UNSIGNED_BYTE, render_local);
                    glDrawArrays(GL_TRIANGLES, 0, 6);
                    clock_gettime(CLOCK_MONOTONIC, &t4b);

                    if (!eglSwapBuffers(g_egl_display, g_egl_surface)) {
                        LOGE("eglSwapBuffers failed: 0x%x", eglGetError());
                        gl_teardown();
                        gl_disabled = 1;
                    } else {
                        did_present = 1;
                    }
                    clock_gettime(CLOCK_MONOTONIC, &t5);
                }
            }

            if (!did_present) {
                clock_gettime(CLOCK_MONOTONIC, &t4a);
                if (g_color_mode) {
                    blit_rgb_to_surface(g_window, render_local);
                } else {
                    blit_grey_to_surface(g_window, render_local);
                }
                clock_gettime(CLOCK_MONOTONIC, &t4b);
                clock_gettime(CLOCK_MONOTONIC, &t5);
                did_present = 1;
            }

            if (did_present) {
                pthread_mutex_lock(&g_frame_mutex);
                g_render_neon_sum += ms_diff(t4a, t4b);
                g_render_vsync_sum += ms_diff(t4b, t5);
                g_render_stat_frames += 1;
                pthread_mutex_unlock(&g_frame_mutex);
            }
        }
    }

    gl_teardown();
    free(render_local);
    return NULL;
}

static void *decode_thread(void *arg) {
    (void)arg;
    LOGI("Decode thread started, connecting to %s:%d", g_host, g_port);

    g_current_frame = (uint8_t *)calloc(g_buffer_size, 1);
    g_compressed_buf = (uint8_t *)malloc(g_max_compressed);
    uint8_t *decompress_buf = (uint8_t *)malloc(g_buffer_size);
    g_render_frames[0] = (uint8_t *)malloc(g_buffer_size);
    g_render_frames[1] = (uint8_t *)malloc(g_buffer_size);

    if (!g_current_frame || !g_compressed_buf || !decompress_buf || !g_render_frames[0] || !g_render_frames[1]) {
        LOGE("Failed to allocate buffers");
        goto cleanup;
    }
    memset(g_render_frames[0], 0xFF, g_buffer_size);
    memset(g_render_frames[1], 0xFF, g_buffer_size);

    while (g_running) {
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            LOGE("socket() failed: %s", strerror(errno));
            sleep(1);
            continue;
        }

        int flag = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(g_port);
        inet_pton(AF_INET, g_host, &addr.sin_addr);

        LOGI("Connecting to %s:%d ...", g_host, g_port);
        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            LOGE("connect() failed: %s (is ADB reverse tunnel set up?)", strerror(errno));
            close(sock);
            sleep(1);
            continue;
        }

        g_sock = sock;
        LOGI("Connected to server %s:%d", g_host, g_port);

        int frame_count = 0;
        int stat_frames = 0;
        int dropped_frames = 0;
        int skipped_deltas = 0;
        uint32_t last_seq = 0;
        int has_last_seq = 0;
        double recv_sum = 0, decomp_sum = 0, delta_sum = 0;
        struct timespec stat_start;
        clock_gettime(CLOCK_MONOTONIC, &stat_start);

        while (g_running) {
            struct timespec t0, t1, t2, t3;
            clock_gettime(CLOCK_MONOTONIC, &t0);

            uint8_t magic[2];
            if (read_exact(sock, magic, 2) < 0) {
                LOGE("Connection lost");
                break;
            }
            if (magic[0] != MAGIC_FRAME_0) {
                LOGE("Bad magic: 0x%02x 0x%02x", magic[0], magic[1]);
                break;
            }

            if (magic[1] == MAGIC_CMD_1) {
                uint8_t cmd;
                if (read_exact(sock, &cmd, 1) < 0) break;

                if (cmd == CMD_RESOLUTION) {
                    uint8_t res_data[4];
                    if (read_exact(sock, res_data, 4) < 0) break;
                    uint32_t new_w = res_data[0] | (res_data[1] << 8);
                    uint32_t new_h = res_data[2] | (res_data[3] << 8);
                    if (new_w > 0 && new_h > 0 && new_w <= 4096 && new_h <= 4096) {
                        if (reallocate_buffers(new_w, new_h, &decompress_buf)) {
                            if (g_window) {
                                ANativeWindow_setBuffersGeometry(g_window, new_w, new_h,
                                    AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);
                            }
                            LOGI("Resolution → %ux%u (%u pixels)", new_w, new_h, g_pixel_count);
                        } else {
                            LOGE("Resolution change allocation failed");
                        }
                    }
                    continue;
                }

                if (cmd == CMD_COLOR_MODE) {
                    uint8_t mode;
                    if (read_exact(sock, &mode, 1) < 0) break;
                    int new_color = mode ? 1 : 0;
                    if (new_color != g_color_mode) {
                        g_color_mode = new_color;
                        g_bytes_per_pixel = new_color ? 3 : 1;
                        LOGI("Color mode → %s (%d bytes/pixel)", new_color ? "color" : "greyscale", g_bytes_per_pixel);
                        // Reallocate buffers with new bytes_per_pixel
                        if (reallocate_buffers(g_frame_w, g_frame_h, &decompress_buf)) {
                            LOGI("Buffers reallocated for %s mode", new_color ? "color" : "greyscale");
                        } else {
                            LOGE("Buffer reallocation failed for color mode change");
                        }
                    }
                    continue;
                }

                if (cmd == CMD_REFRESH) {
                    // Refresh has no value byte — trigger full e-ink refresh
                    if (g_jvm && g_activity) {
                        JNIEnv *env;
                        int attached = 0;
                        if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
                            (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
                            attached = 1;
                        }
                        jclass cls = (*env)->GetObjectClass(env, g_activity);
                        jmethodID mid = (*env)->GetMethodID(env, cls, "refreshScreen", "()V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid);
                        if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
                    }
                    continue;
                }

                uint8_t value;
                if (read_exact(sock, &value, 1) < 0) break;
                if (g_jvm && g_activity) {
                    JNIEnv *env;
                    int attached = 0;
                    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
                        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
                        attached = 1;
                    }
                    jclass cls = (*env)->GetObjectClass(env, g_activity);
                    if (cmd == CMD_BRIGHTNESS) {
                        jmethodID mid = (*env)->GetMethodID(env, cls, "setBrightness", "(I)V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
                    } else if (cmd == CMD_WARMTH) {
                        jmethodID mid = (*env)->GetMethodID(env, cls, "setWarmth", "(I)V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
                    }
                    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
                }
                continue;
            }

            if (magic[1] != MAGIC_FRAME_1) {
                LOGE("Unknown packet type: 0x%02x", magic[1]);
                break;
            }

            uint8_t frame_hdr[9];
            if (read_exact(sock, frame_hdr, 9) < 0) {
                LOGE("Connection lost reading frame header");
                break;
            }

            uint8_t flags = frame_hdr[0];
            uint32_t seq = frame_hdr[1] | (frame_hdr[2] << 8) | (frame_hdr[3] << 16) | (frame_hdr[4] << 24);
            uint32_t payload_len = frame_hdr[5] | (frame_hdr[6] << 8) | (frame_hdr[7] << 16) | (frame_hdr[8] << 24);

            if (has_last_seq && seq != last_seq + 1) {
                int gap = (int)(seq - last_seq - 1);
                if (gap > 0 && gap < 1000) dropped_frames += gap;
            }
            last_seq = seq;
            has_last_seq = 1;

            if (payload_len > g_max_compressed) {
                LOGE("Payload too large: %u", payload_len);
                break;
            }

            if (read_exact(sock, g_compressed_buf, payload_len) < 0) {
                LOGE("Failed to read payload");
                break;
            }
            clock_gettime(CLOCK_MONOTONIC, &t1);

            if (flags & FLAG_TILED) {
                // Tiled frame: parse header, decompress and apply only dirty tiles
                if (payload_len < 4) { continue; }
                const uint8_t *p = g_compressed_buf;
                uint16_t tile_cols = p[0] | (p[1] << 8);
                uint16_t tile_rows = p[2] | (p[3] << 8);
                p += 4;

                int tile_count = tile_cols * tile_rows;
                int bitmap_bytes = (tile_count + 7) / 8;
                if ((uint32_t)(4 + bitmap_bytes) > payload_len) { continue; }
                const uint8_t *bitmap = p;
                p += bitmap_bytes;

                int tile_size = 64;  // TILE_SIZE
                int bpp = g_bytes_per_pixel;
                int tile_max_pixels = tile_size * tile_size * bpp;

                for (int ty = 0; ty < tile_rows; ty++) {
                    int tile_h = tile_size;
                    if (ty * tile_size + tile_h > (int)g_frame_h)
                        tile_h = (int)g_frame_h - ty * tile_size;
                    for (int tx = 0; tx < tile_cols; tx++) {
                        int tile_idx = ty * tile_cols + tx;
                        if (!(bitmap[tile_idx / 8] & (1 << (tile_idx % 8)))) continue;

                        int tile_w = tile_size;
                        if (tx * tile_size + tile_w > (int)g_frame_w)
                            tile_w = (int)g_frame_w - tx * tile_size;

                        // Read compressed tile length
                        if ((uint32_t)(p - g_compressed_buf + 4) > payload_len) goto tiled_done;
                        uint32_t comp_len = p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24);
                        p += 4;
                        if ((uint32_t)(p - g_compressed_buf + comp_len) > payload_len) goto tiled_done;

                        // Decompress tile delta
                        int tile_data_size = tile_w * tile_h * bpp;
                        int decomp = LZ4_decompress_safe((const char *)p, (char *)decompress_buf,
                                                         (int)comp_len, tile_max_pixels);
                        p += comp_len;

                        if (decomp != tile_data_size) {
                            LOGE("Tile LZ4 decompress failed: got %d, expected %d", decomp, tile_data_size);
                            continue;
                        }

                        // Apply XOR delta to tile region in g_current_frame
                        int delta_offset = 0;
                        for (int row = 0; row < tile_h; row++) {
                            int y = ty * tile_size + row;
                            int frame_offset = (y * (int)g_frame_w + tx * tile_size) * bpp;
                            int row_len = tile_w * bpp;
                            apply_delta_neon(g_current_frame + frame_offset,
                                             decompress_buf + delta_offset, row_len);
                            delta_offset += row_len;
                        }
                    }
                }
                tiled_done:
                clock_gettime(CLOCK_MONOTONIC, &t2);
                clock_gettime(CLOCK_MONOTONIC, &t3);
            } else {
                int decompressed_size = LZ4_decompress_safe(
                    (const char *)g_compressed_buf,
                    (char *)decompress_buf,
                    payload_len,
                    g_buffer_size
                );
                clock_gettime(CLOCK_MONOTONIC, &t2);

                if (decompressed_size != (int)g_buffer_size) {
                    LOGE("LZ4 decompress failed: got %d, expected %u", decompressed_size, g_buffer_size);
                    if (flags & FLAG_KEYFRAME) break;
                    continue;
                }

                if (flags & FLAG_KEYFRAME) {
                    memcpy(g_current_frame, decompress_buf, g_buffer_size);
                } else if (payload_len < 256) {
                    skipped_deltas += 1;
                } else {
                    apply_delta_neon(g_current_frame, decompress_buf, g_buffer_size);
                }
                clock_gettime(CLOCK_MONOTONIC, &t3);
            }

            send_ack(sock, seq);
            publish_frame(g_current_frame, seq);

            // Notify connected only after first frame is rendered
            // (TCP connect alone doesn't mean the server is streaming)
            if (frame_count == 0) {
                notify_connection_state(1);
            }

            recv_sum += ms_diff(t0, t1);
            decomp_sum += ms_diff(t1, t2);
            delta_sum += ms_diff(t2, t3);
            frame_count += 1;
            stat_frames += 1;

            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (now.tv_sec - stat_start.tv_sec) +
                             (now.tv_nsec - stat_start.tv_nsec) / 1e9;
            if (elapsed >= 5.0 && stat_frames > 0) {
                double fps = stat_frames / elapsed;
                pthread_mutex_lock(&g_frame_mutex);
                double neon_avg = g_render_stat_frames > 0 ? (g_render_neon_sum / g_render_stat_frames) : 0.0;
                double vsync_avg = g_render_stat_frames > 0 ? (g_render_vsync_sum / g_render_stat_frames) : 0.0;
                int overwritten = g_overwritten_frames;
                g_render_neon_sum = 0.0;
                g_render_vsync_sum = 0.0;
                g_render_stat_frames = 0;
                g_overwritten_frames = 0;
                pthread_mutex_unlock(&g_frame_mutex);

                LOGI("FPS: %.1f | recv: %.1fms | lz4: %.1fms | delta: %.1fms | neon: %.1fms | vsync: %.1fms | %uKB %s | drops: %d | skip: %d | overwritten: %d | total: %d",
                     fps,
                     recv_sum / stat_frames,
                     decomp_sum / stat_frames,
                     delta_sum / stat_frames,
                     neon_avg,
                     vsync_avg,
                     payload_len / 1024,
                     (flags & FLAG_KEYFRAME) ? "KF" : "delta",
                     dropped_frames,
                     skipped_deltas,
                     overwritten,
                     frame_count);

                stat_frames = 0;
                recv_sum = 0;
                decomp_sum = 0;
                delta_sum = 0;
                skipped_deltas = 0;
                stat_start = now;
            }
        }

        if (g_sock >= 0) {
            close(g_sock);
            g_sock = -1;
        }
        LOGI("Disconnected, reconnecting in 1s...");

        if (g_current_frame) {
            memset(g_current_frame, 0xFF, g_buffer_size);
            publish_frame(g_current_frame, g_ready_seq + 1);
        }

        notify_connection_state(0);
        sleep(1);
    }

cleanup:
    if (g_sock >= 0) {
        close(g_sock);
        g_sock = -1;
    }
    free(g_current_frame); g_current_frame = NULL;
    free(g_compressed_buf); g_compressed_buf = NULL;
    free(decompress_buf);
    free(g_render_frames[0]); g_render_frames[0] = NULL;
    free(g_render_frames[1]); g_render_frames[1] = NULL;
    pthread_mutex_lock(&g_frame_mutex);
    g_has_ready_frame = 0;
    pthread_mutex_unlock(&g_frame_mutex);
    pthread_cond_signal(&g_frame_cond);
    LOGI("Decode thread exited");
    return NULL;
}

// JNI: called from Kotlin when Surface is ready
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStart(
    JNIEnv *env, jobject thiz, jobject surface, jstring host, jint port)
{
    if (g_running) return;

    (*env)->GetJavaVM(env, &g_jvm);
    g_activity = (*env)->NewGlobalRef(env, thiz);

    g_window = ANativeWindow_fromSurface(env, surface);
    ANativeWindow_setBuffersGeometry(g_window, g_frame_w, g_frame_h,
        AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);

    const char *host_str = (*env)->GetStringUTFChars(env, host, NULL);
    strncpy(g_host, host_str, sizeof(g_host) - 1);
    (*env)->ReleaseStringUTFChars(env, host, host_str);
    g_port = port;

    g_running = 1;
    pthread_create(&g_render_thread, NULL, render_thread, NULL);
    pthread_create(&g_decode_thread, NULL, decode_thread, NULL);
}

// JNI: called from Kotlin to forward touch events to Mac
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeSendTouch(
    JNIEnv *env, jobject thiz, jint action, jint x_norm, jint y_norm)
{
    send_touch_event(action, x_norm, y_norm);
}

// JNI: called from Kotlin to forward two-finger scroll to Mac
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeSendScroll(
    JNIEnv *env, jobject thiz, jint x_norm, jint y_norm, jint delta_y)
{
    send_scroll_event(x_norm, y_norm, delta_y);
}

// JNI: called from Kotlin when Surface is destroyed
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStop(
    JNIEnv *env, jobject thiz)
{
    g_running = 0;
    pthread_cond_broadcast(&g_frame_cond);
    if (g_sock >= 0) {
        shutdown(g_sock, SHUT_RDWR);
        close(g_sock);
        g_sock = -1;
    }
    pthread_join(g_decode_thread, NULL);
    pthread_join(g_render_thread, NULL);
    if (g_window) {
        ANativeWindow_release(g_window);
        g_window = NULL;
    }
    if (g_activity) {
        (*env)->DeleteGlobalRef(env, g_activity);
        g_activity = NULL;
    }
}
