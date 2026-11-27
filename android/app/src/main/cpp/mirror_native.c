// mirror_native.c — Daylight/BOOX Mirror native renderer.
//
// Receives LZ4+delta compressed frames over TCP (greyscale 1 B/px or RGB 3 B/px),
// decompresses, applies the delta, and renders via a GL texture (CPU blit fallback).
// Entire hot path is C — no JNI calls per frame, no Java GC.
//
// Protocol: [0xDA 0x7E] [flags:1B] [seq:4B LE] [length:4B LE] [payload]
//   flags 0x01: keyframe — payload is LZ4(frame)
//   flags 0x02: tiled delta — [cols:2][rows:2][dirty bitmap] + per dirty tile
//               [lz4_len:4][LZ4(XOR of the tile's rows)] (64x64 tiles, row-major)
//   flags 0x00: full-frame delta — payload is LZ4(frame XOR previous)
// Commands: [0xDA 0x7F] [cmd:1B] [value...] — see CMD_* below.
// ACK:      [0xDA 0x7A] [seq:4B LE] — sent back after decoding each frame

#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/select.h>
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
#define FLAG_TILED    0x02
#define FRAME_HEADER_SIZE 11
#define TILE_SIZE 64
#define CMD_BRIGHTNESS 0x01
#define CMD_WARMTH     0x02
#define CMD_RESOLUTION 0x04
#define CMD_COLOR_MODE 0x05
#define CMD_REFRESH    0x06
#define CMD_EINK_MODE  0x07

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
// Set by nativeSwitchToUSB(): drop the Wi-Fi stream and reconnect through the USB tunnel
// without blanking the panel.
static volatile int g_switching = 0;

// Connection candidates, tried in order: the USB tunnel (127.0.0.1) first, then Mac
// addresses on Wi-Fi (handed over by the Mac via USB, or found by Bonjour). Non-loopback
// connections start with an auth packet carrying the pairing secret.
#define MAX_HOSTS 8
#define AUTH_TOKEN_LEN 16
static char g_hosts[MAX_HOSTS][64] = {"127.0.0.1"};
static int g_host_count = 1;
static int g_host_index = 0;
static pthread_mutex_t g_host_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_token[AUTH_TOKEN_LEN];
static int g_has_token = 0;

// Dynamic frame dimensions (set by CMD_RESOLUTION before first frame)
static uint32_t g_frame_w = DEFAULT_FRAME_W;
static uint32_t g_frame_h = DEFAULT_FRAME_H;
// Actual surface dimensions from surfaceChanged — the real window size after
// any orientation change. Some devices (Boox Palma) claim to rotate but the
// DC-1 framebuffer stays portrait, so we use this to detect the truth.
static uint32_t g_surface_w = 0;
static uint32_t g_surface_h = 0;
static uint32_t g_pixel_count = DEFAULT_FRAME_W * DEFAULT_FRAME_H;
// Bytes per pixel: 1 = greyscale, 3 = RGB (set by CMD_COLOR_MODE before CMD_RESOLUTION)
static uint32_t g_bpp = 1;
static uint32_t g_buffer_size = DEFAULT_FRAME_W * DEFAULT_FRAME_H;  // g_pixel_count * g_bpp
static uint32_t g_max_compressed = DEFAULT_FRAME_W * DEFAULT_FRAME_H + (DEFAULT_FRAME_W * DEFAULT_FRAME_H / 255) + 1024;
// Monotonic ms of the last decoded frame — polled by Kotlin for e-ink auto mode.
static volatile int64_t g_last_frame_ms = 0;

// Frame buffers (allocated once, reused — reallocated on resolution change)
static uint8_t *g_current_frame = NULL;   // Decompressed greyscale pixels
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
static uint32_t g_gl_tex_bpp = 0;
static int g_gl_ready = 0;
static int g_gl_rotated = 0;  // 1 = currently using rotated quad vertices

// Normal quad: no rotation (frame and surface have same orientation)
static const GLfloat k_quad_vertices[] = {
    -1.0f, -1.0f, 0.0f, 1.0f,
     1.0f, -1.0f, 1.0f, 1.0f,
    -1.0f,  1.0f, 0.0f, 0.0f,
    -1.0f,  1.0f, 0.0f, 0.0f,
     1.0f, -1.0f, 1.0f, 1.0f,
     1.0f,  1.0f, 1.0f, 0.0f,
};
// Rotated 90° CW: landscape frame on portrait surface.
// When user holds device sideways (CCW), content appears upright.
static const GLfloat k_quad_vertices_rot90[] = {
    -1.0f, -1.0f, 1.0f, 1.0f,
     1.0f, -1.0f, 1.0f, 0.0f,
    -1.0f,  1.0f, 0.0f, 1.0f,
    -1.0f,  1.0f, 0.0f, 1.0f,
     1.0f, -1.0f, 1.0f, 0.0f,
     1.0f,  1.0f, 0.0f, 0.0f,
};

static const char *k_vertex_shader_src =
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texcoord;\n"
    "varying vec2 v_texcoord;\n"
    "void main() {\n"
    "    gl_Position = a_position;\n"
    "    v_texcoord = a_texcoord;\n"
    "}\n";

// Fragment shader — passthrough.  Sampling .rgb works for both texture formats:
// a GL_LUMINANCE texel reads back as (L, L, L), a GL_RGB texel as (R, G, B).
// All image processing (greyscale, sharpen,
// contrast, gamma) is done Mac-side in the combined LUT.  An earlier version
// applied smoothstep(0.08, 0.92) here to snap antialiasing fringes to B/W,
// but combined with the Mac-side gamma+contrast LUT it crushed light greys
// (everything above ~200 became pure white) and dark greys (below ~30 became
// pure black), destroying contrast discrimination.  The Mac LUT alone is
// sufficient for text crispness; the shader should not double-process.
static const char *k_fragment_shader_src =
    "precision mediump float;\n"
    "varying vec2 v_texcoord;\n"
    "uniform sampler2D u_texture;\n"
    "void main() {\n"
    "    gl_FragColor = vec4(texture2D(u_texture, v_texcoord).rgb, 1.0);\n"
    "}\n";

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
    GLuint vertex_shader = gl_compile_shader(GL_VERTEX_SHADER, k_vertex_shader_src);
    GLuint fragment_shader = gl_compile_shader(GL_FRAGMENT_SHADER, k_fragment_shader_src);
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

    return 1;
}

static GLenum gl_format_for_bpp(uint32_t bpp) { return bpp == 3 ? GL_RGB : GL_LUMINANCE; }

static int gl_create_texture(uint32_t width, uint32_t height, uint32_t bpp) {
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
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    GLenum fmt = gl_format_for_bpp(bpp);
    glTexImage2D(GL_TEXTURE_2D, 0, fmt, (GLsizei)width, (GLsizei)height,
                 0, fmt, GL_UNSIGNED_BYTE, NULL);

    if (glGetError() != GL_NO_ERROR) {
        LOGE("glTexImage2D failed for %ux%u (%s)", width, height, bpp == 3 ? "RGB" : "LUMINANCE");
        glDeleteTextures(1, &g_gl_texture);
        g_gl_texture = 0;
        return 0;
    }

    g_gl_tex_w = width;
    g_gl_tex_h = height;
    g_gl_tex_bpp = bpp;
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
    glBufferData(GL_ARRAY_BUFFER, sizeof(k_quad_vertices), k_quad_vertices, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    g_gl_rotated = 0;

    if (!gl_create_texture(g_frame_w, g_frame_h, g_bpp)) goto fail;

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    g_gl_ready = 1;
    return 1;

fail:
    gl_teardown();
    return 0;
}

static int gl_ensure_texture_size(uint32_t width, uint32_t height, uint32_t bpp) {
    if (!g_gl_ready) return 0;
    if (g_gl_texture && g_gl_tex_w == width && g_gl_tex_h == height && g_gl_tex_bpp == bpp) return 1;
    return gl_create_texture(width, height, bpp);
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
    g_gl_tex_bpp = 0;
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

// Write greyscale directly to ANativeWindow in R8_UNORM format (1 byte/pixel).
// Falls back to RGBX expansion if R8 is not supported.
static int g_r8_supported = 0;  // R8_UNORM not compositable by SurfaceFlinger on DC-1

static void blit_grey_to_surface(ANativeWindow *window, const uint8_t *grey) {
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) {
        LOGE("ANativeWindow_lock failed");
        return;
    }

    uint8_t *dst = (uint8_t *)buffer.bits;
    int fw = (int)g_frame_w;
    int fh = (int)g_frame_h;

    if (g_r8_supported) {
        if (buffer.stride == fw && fw <= buffer.width && fh <= buffer.height) {
            memcpy(dst, grey, (size_t)fw * fh);
        } else {
            int dst_stride = buffer.stride;
            for (int y = 0; y < fh && y < buffer.height; y++) {
                int w = fw < buffer.width ? fw : buffer.width;
                memcpy(dst + y * dst_stride, grey + y * fw, w);
            }
        }
    } else {
        // Fallback: RGBX_8888 (4 bytes per pixel) with NEON expansion
        int dst_stride = buffer.stride * 4;
        for (int y = 0; y < fh && y < buffer.height; y++) {
            uint8_t *row = dst + y * dst_stride;
            const uint8_t *src = grey + y * fw;
            int x = 0;
            for (; x + 16 <= fw && x + 16 <= buffer.width; x += 16) {
                uint8x16_t g = vld1q_u8(src + x);
                uint8x16_t ff = vdupq_n_u8(0xFF);
                uint8x16x4_t rgbx;
                rgbx.val[0] = g;
                rgbx.val[1] = g;
                rgbx.val[2] = g;
                rgbx.val[3] = ff;
                vst4q_u8(row + x * 4, rgbx);
            }
            for (; x < fw && x < buffer.width; x++) {
                uint8_t v = src[x];
                row[x * 4 + 0] = v;
                row[x * 4 + 1] = v;
                row[x * 4 + 2] = v;
                row[x * 4 + 3] = 0xFF;
            }
        }
    }

    ANativeWindow_unlockAndPost(window);
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

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Call a void Java method on the activity: no args ("()V") or one int ("(I)V").
static void call_activity(const char *name, int has_arg, int value) {
    if (!g_jvm || !g_activity) return;
    JNIEnv *env;
    int attached = 0;
    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
        attached = 1;
    }
    jclass cls = (*env)->GetObjectClass(env, g_activity);
    jmethodID mid = (*env)->GetMethodID(env, cls, name, has_arg ? "(I)V" : "()V");
    if (mid) {
        if (has_arg) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
        else (*env)->CallVoidMethod(env, g_activity, mid);
    } else {
        (*env)->ExceptionClear(env);
        LOGE("Activity method %s not found", name);
    }
    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
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

static int reallocate_buffers(uint32_t new_w, uint32_t new_h, uint32_t new_bpp, uint8_t **decompress_buf) {
    uint32_t new_pixels = new_w * new_h;
    uint32_t new_size = new_pixels * new_bpp;
    // LZ4 worst-case: input_size + input_size/255 + 16. Tiled payloads add a header,
    // bitmap and a 4-byte length per tile; use a generous margin for both.
    uint32_t tiles = ((new_w + TILE_SIZE - 1) / TILE_SIZE) * ((new_h + TILE_SIZE - 1) / TILE_SIZE);
    uint32_t new_max_compressed = new_size + (new_size / 255) + tiles * 24 + 4096;

    uint8_t *new_current = (uint8_t *)calloc(new_size, 1);
    uint8_t *new_compressed = (uint8_t *)malloc(new_max_compressed);
    uint8_t *new_decompress = (uint8_t *)malloc(new_size);
    uint8_t *new_render0 = (uint8_t *)malloc(new_size);
    uint8_t *new_render1 = (uint8_t *)malloc(new_size);

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
    memset(g_render_frames[0], 0xFF, new_size);
    memset(g_render_frames[1], 0xFF, new_size);
    g_ready_index = 0;
    g_has_ready_frame = 0;

    g_frame_w = new_w;
    g_frame_h = new_h;
    g_bpp = new_bpp;
    g_pixel_count = new_pixels;
    g_buffer_size = new_size;
    g_max_compressed = new_max_compressed;
    pthread_mutex_unlock(&g_frame_mutex);
    return 1;
}

// Apply a tiled delta payload to g_current_frame. Returns 0 on a malformed payload.
static int apply_tiled_delta(const uint8_t *payload, uint32_t payload_len, uint8_t *scratch) {
    if (payload_len < 4) return 0;
    const uint8_t *p = payload;
    const uint8_t *end = payload + payload_len;
    uint32_t cols = p[0] | (p[1] << 8);
    uint32_t rows = p[2] | (p[3] << 8);
    p += 4;
    uint32_t expect_cols = (g_frame_w + TILE_SIZE - 1) / TILE_SIZE;
    uint32_t expect_rows = (g_frame_h + TILE_SIZE - 1) / TILE_SIZE;
    if (cols != expect_cols || rows != expect_rows) {
        LOGE("Tiled frame grid %ux%u does not match %ux%u", cols, rows, expect_cols, expect_rows);
        return 0;
    }
    uint32_t tile_count = cols * rows;
    uint32_t bitmap_bytes = (tile_count + 7) / 8;
    if ((uint32_t)(end - p) < bitmap_bytes) return 0;
    const uint8_t *bitmap = p;
    p += bitmap_bytes;

    const int bpp = (int)g_bpp;
    const int stride = (int)g_frame_w * bpp;
    const int tile_max = TILE_SIZE * TILE_SIZE * bpp;
    for (uint32_t ty = 0; ty < rows; ty++) {
        int tile_h = TILE_SIZE;
        if ((int)(ty * TILE_SIZE) + tile_h > (int)g_frame_h) tile_h = (int)g_frame_h - (int)(ty * TILE_SIZE);
        for (uint32_t tx = 0; tx < cols; tx++) {
            uint32_t idx = ty * cols + tx;
            if (!(bitmap[idx >> 3] & (1 << (idx & 7)))) continue;
            int tile_w = TILE_SIZE;
            if ((int)(tx * TILE_SIZE) + tile_w > (int)g_frame_w) tile_w = (int)g_frame_w - (int)(tx * TILE_SIZE);

            if (end - p < 4) return 0;
            uint32_t comp_len = p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
            p += 4;
            if ((uint32_t)(end - p) < comp_len) return 0;

            const int row_len = tile_w * bpp;
            const int tile_bytes = row_len * tile_h;
            int got = LZ4_decompress_safe((const char *)p, (char *)scratch, (int)comp_len, tile_max);
            p += comp_len;
            if (got != tile_bytes) {
                LOGE("Tile %u LZ4 failed: got %d, expected %d", idx, got, tile_bytes);
                return 0;
            }
            uint8_t *dst = g_current_frame + (size_t)ty * TILE_SIZE * stride + (size_t)tx * TILE_SIZE * bpp;
            const uint8_t *src = scratch;
            for (int r = 0; r < tile_h; r++) {
                apply_delta_neon(dst, src, row_len);
                dst += stride;
                src += row_len;
            }
        }
    }
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
        uint32_t local_pixels = g_buffer_size;  // bytes, not pixels (RGB = 3 B/px)
        uint32_t render_bpp = g_bpp;
        render_w = g_frame_w;
        render_h = g_frame_h;

        if (local_pixels > render_capacity) {
            uint8_t *resized = (uint8_t *)realloc(render_local, local_pixels);
            if (!resized) {
                g_has_ready_frame = 0;
                pthread_mutex_unlock(&g_frame_mutex);
                continue;
            }
            render_local = resized;
            render_capacity = local_pixels;
        }

        memcpy(render_local, g_render_frames[frame_index], local_pixels);
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

                if (g_gl_ready && !gl_ensure_texture_size(render_w, render_h, render_bpp)) {
                    LOGE("GL texture resize failed for %ux%u", render_w, render_h);
                    gl_teardown();
                    gl_disabled = 1;
                }

                if (g_gl_ready) {
                    EGLint surface_w = 0;
                    EGLint surface_h = 0;
                    eglQuerySurface(g_egl_display, g_egl_surface, EGL_WIDTH, &surface_w);
                    eglQuerySurface(g_egl_display, g_egl_surface, EGL_HEIGHT, &surface_h);

                    // Detect orientation mismatch using actual surface dimensions
                    // (from surfaceChanged). Some devices report rotation=LANDSCAPE
                    // but the physical framebuffer stays portrait (Boox Palma).
                    int frame_is_landscape = (render_w > render_h) ? 1 : 0;
                    int surface_is_landscape = (g_surface_w > g_surface_h) ? 1 : 0;
                    int need_rotation = (g_surface_w > 0 && frame_is_landscape != surface_is_landscape) ? 1 : 0;

                    // Aspect-fit: never stretch. If the frame's aspect differs from the
                    // surface (e.g. firmware reserves part of the panel), center it and
                    // leave white bars — white is "off" on paper-like panels.
                    if (surface_w > 0 && surface_h > 0) {
                        double fw = need_rotation ? (double)render_h : (double)render_w;
                        double fh = need_rotation ? (double)render_w : (double)render_h;
                        double scale = (double)surface_w / fw;
                        if ((double)surface_h / fh < scale) scale = (double)surface_h / fh;
                        GLint vw = (GLint)(fw * scale + 0.5);
                        GLint vh = (GLint)(fh * scale + 0.5);
                        if (vw > surface_w) vw = surface_w;
                        if (vh > surface_h) vh = surface_h;
                        GLint vx = (surface_w - vw) / 2;
                        GLint vy = (surface_h - vh) / 2;
                        if (vw != surface_w || vh != surface_h) {
                            glViewport(0, 0, surface_w, surface_h);
                            glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
                            glClear(GL_COLOR_BUFFER_BIT);
                        }
                        glViewport(vx, vy, vw, vh);
                    }
                    if (need_rotation != g_gl_rotated) {
                        g_gl_rotated = need_rotation;
                        glBindBuffer(GL_ARRAY_BUFFER, g_gl_vbo);
                        if (need_rotation) {
                            glBufferData(GL_ARRAY_BUFFER, sizeof(k_quad_vertices_rot90),
                                         k_quad_vertices_rot90, GL_STATIC_DRAW);
                            LOGI("Rotation: enabled (frame %ux%u, surface %ux%u)",
                                 render_w, render_h, g_surface_w, g_surface_h);
                        } else {
                            glBufferData(GL_ARRAY_BUFFER, sizeof(k_quad_vertices),
                                         k_quad_vertices, GL_STATIC_DRAW);
                            LOGI("Rotation: disabled (orientations match)");
                        }
                        glBindBuffer(GL_ARRAY_BUFFER, 0);
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
                    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                                    (GLsizei)render_w, (GLsizei)render_h,
                                    gl_format_for_bpp(render_bpp), GL_UNSIGNED_BYTE, render_local);
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
                ANativeWindow_Buffer nbuf;
                if (ANativeWindow_lock(g_window, &nbuf, NULL) == 0) {
                    clock_gettime(CLOCK_MONOTONIC, &t4a);
                    uint8_t *dst = (uint8_t *)nbuf.bits;
                    int dst_stride = nbuf.stride * 4;
                    int fw = (int)render_w;
                    int fh = (int)render_h;

                    // Check if we need to rotate (landscape frame on portrait surface)
                    int cpu_frame_landscape = (fw > fh) ? 1 : 0;
                    int cpu_surface_landscape = (g_surface_w > g_surface_h) ? 1 : 0;
                    int cpu_need_rotation = (g_surface_w > 0 && cpu_frame_landscape != cpu_surface_landscape) ? 1 : 0;

                    if (cpu_need_rotation) {
                        // 90° CW rotation: frame(x,y) → screen(fh-1-y, x)
                        // Output dimensions: width=fh, height=fw
                        int out_w = fh < nbuf.width ? fh : nbuf.width;
                        int out_h = fw < nbuf.height ? fw : nbuf.height;
                        for (int sy = 0; sy < out_h; sy++) {
                            uint8_t *row = dst + sy * dst_stride;
                            for (int sx = 0; sx < out_w; sx++) {
                                // Screen (sx,sy) → frame (sy, fh-1-sx)
                                const uint8_t *px = render_local + (((size_t)(fh - 1 - sx) * fw) + sy) * render_bpp;
                                row[sx * 4 + 0] = px[0];
                                row[sx * 4 + 1] = px[render_bpp == 3 ? 1 : 0];
                                row[sx * 4 + 2] = px[render_bpp == 3 ? 2 : 0];
                                row[sx * 4 + 3] = 0xFF;
                            }
                        }
                    } else {
                        for (int y = 0; y < fh && y < nbuf.height && render_bpp == 3; y++) {
                            uint8_t *row = dst + y * dst_stride;
                            const uint8_t *row_src = render_local + (size_t)y * fw * 3;
                            int x = 0;
                            for (; x + 16 <= fw && x + 16 <= nbuf.width; x += 16) {
                                uint8x16x3_t rgb = vld3q_u8(row_src + x * 3);
                                uint8x16x4_t rgbx;
                                rgbx.val[0] = rgb.val[0];
                                rgbx.val[1] = rgb.val[1];
                                rgbx.val[2] = rgb.val[2];
                                rgbx.val[3] = vdupq_n_u8(0xFF);
                                vst4q_u8(row + x * 4, rgbx);
                            }
                            for (; x < fw && x < nbuf.width; x++) {
                                row[x * 4 + 0] = row_src[x * 3 + 0];
                                row[x * 4 + 1] = row_src[x * 3 + 1];
                                row[x * 4 + 2] = row_src[x * 3 + 2];
                                row[x * 4 + 3] = 0xFF;
                            }
                        }
                        for (int y = 0; y < fh && y < nbuf.height && render_bpp == 1; y++) {
                            uint8_t *row = dst + y * dst_stride;
                            const uint8_t *row_src = render_local + y * fw;
                            int x = 0;
                            for (; x + 16 <= fw && x + 16 <= nbuf.width; x += 16) {
                                uint8x16_t g = vld1q_u8(row_src + x);
                                uint8x16_t ff = vdupq_n_u8(0xFF);
                                uint8x16x4_t rgbx;
                                rgbx.val[0] = g;
                                rgbx.val[1] = g;
                                rgbx.val[2] = g;
                                rgbx.val[3] = ff;
                                vst4q_u8(row + x * 4, rgbx);
                            }
                            for (; x < fw && x < nbuf.width; x++) {
                                uint8_t v = row_src[x];
                                row[x * 4 + 0] = v;
                                row[x * 4 + 1] = v;
                                row[x * 4 + 2] = v;
                                row[x * 4 + 3] = 0xFF;
                            }
                        }
                    }
                    clock_gettime(CLOCK_MONOTONIC, &t4b);
                    ANativeWindow_unlockAndPost(g_window);
                    clock_gettime(CLOCK_MONOTONIC, &t5);
                    did_present = 1;
                }
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

static int is_loopback_host(const char *host) {
    return strncmp(host, "127.", 4) == 0 || strcmp(host, "localhost") == 0;
}

/// TCP connect with a timeout so an unreachable Wi-Fi address can't stall the loop
/// (a blocking connect waits ~75 s). Returns 0 on success.
static int connect_with_timeout(int sock, const struct sockaddr_in *addr, int timeout_ms) {
    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(sock, (const struct sockaddr *)addr, sizeof(*addr));
    if (rc < 0 && errno == EINPROGRESS) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
        rc = select(sock + 1, NULL, &wfds, NULL, &tv);
        if (rc == 1) {
            int err = 0;
            socklen_t len = sizeof(err);
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len);
            if (err == 0) rc = 0; else { errno = err; rc = -1; }
        } else {
            if (rc == 0) errno = ETIMEDOUT;
            rc = -1;
        }
    }
    fcntl(sock, F_SETFL, flags);
    return rc;
}

/// Tell Kotlin which host the stream reached (touch/keyboard connect to the same one).
static void notify_connected_host(const char *host) {
    if (!g_jvm || !g_activity) return;
    JNIEnv *env;
    int attached = 0;
    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
        attached = 1;
    }
    jclass cls = (*env)->GetObjectClass(env, g_activity);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onConnectedHost", "(Ljava/lang/String;)V");
    if (mid) {
        jstring js = (*env)->NewStringUTF(env, host);
        (*env)->CallVoidMethod(env, g_activity, mid, js);
        (*env)->DeleteLocalRef(env, js);
    } else {
        (*env)->ExceptionClear(env);
    }
    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
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

    int failed_in_cycle = 0;
    while (g_running) {
        // Pick the next candidate host
        pthread_mutex_lock(&g_host_mutex);
        if (g_host_index >= g_host_count) g_host_index = 0;
        strncpy(g_host, g_hosts[g_host_index], sizeof(g_host) - 1);
        g_host[sizeof(g_host) - 1] = 0;
        int host_count = g_host_count;
        pthread_mutex_unlock(&g_host_mutex);
        const int loopback = is_loopback_host(g_host);

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
        if (inet_pton(AF_INET, g_host, &addr.sin_addr) != 1) {
            LOGE("Bad host address: %s", g_host);
            close(sock);
            pthread_mutex_lock(&g_host_mutex); g_host_index++; pthread_mutex_unlock(&g_host_mutex);
            continue;
        }

        if (connect_with_timeout(sock, &addr, loopback ? 500 : 1500) < 0) {
            close(sock);
            pthread_mutex_lock(&g_host_mutex); g_host_index++; pthread_mutex_unlock(&g_host_mutex);
            // Pause once every candidate has failed; move straight on otherwise
            if (++failed_in_cycle >= host_count) {
                failed_in_cycle = 0;
                sleep(1);
            }
            continue;
        }
        failed_in_cycle = 0;

        // Network (non-USB) connections must prove they're paired before the Mac streams
        if (!loopback) {
            if (!g_has_token) {
                LOGE("No pairing secret for %s — connect over USB once to pair", g_host);
                close(sock);
                pthread_mutex_lock(&g_host_mutex); g_host_index++; pthread_mutex_unlock(&g_host_mutex);
                sleep(1);
                continue;
            }
            uint8_t auth[2 + AUTH_TOKEN_LEN] = { 0xDA, 0x75 };
            memcpy(auth + 2, g_token, AUTH_TOKEN_LEN);
            if (send(sock, auth, sizeof(auth), MSG_NOSIGNAL) != (ssize_t)sizeof(auth)) {
                close(sock);
                continue;
            }
        }

        g_sock = sock;
        LOGI("Connected to server %s:%d (%s)", g_host, g_port, loopback ? "USB" : "Wi-Fi");
        notify_connected_host(g_host);
        int received_any = 0;

        int frame_count = 0;
        int stat_frames = 0;
        int dropped_frames = 0;
        int tiled_frames = 0;
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
            received_any = 1;
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
                        if (reallocate_buffers(new_w, new_h, g_bpp, &decompress_buf)) {
                            if (g_window) {
                                ANativeWindow_setBuffersGeometry(g_window, new_w, new_h,
                                    AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);
                            }
                            LOGI("Resolution → %ux%u (%u pixels, %u B/px)", new_w, new_h, g_pixel_count, g_bpp);
                            // Kotlin maps touches through the same aspect-fit rect
                            call_activity("onFrameSize", 1, (int)((new_w << 16) | new_h));

                            // Notify Activity to switch orientation for portrait/landscape
                            if (g_jvm && g_activity) {
                                JNIEnv *env2;
                                int attached2 = 0;
                                if ((*g_jvm)->GetEnv(g_jvm, (void **)&env2, JNI_VERSION_1_6) != JNI_OK) {
                                    (*g_jvm)->AttachCurrentThread(g_jvm, &env2, NULL);
                                    attached2 = 1;
                                }
                                jclass cls2 = (*env2)->GetObjectClass(env2, g_activity);
                                jmethodID mid2 = (*env2)->GetMethodID(env2, cls2, "setOrientation", "(Z)V");
                                if (mid2) {
                                    (*env2)->CallVoidMethod(env2, g_activity, mid2,
                                        (jboolean)(new_h > new_w ? 1 : 0));
                                }
                                if (attached2) (*g_jvm)->DetachCurrentThread(g_jvm);
                            }
                        } else {
                            LOGE("Resolution change allocation failed");
                        }
                    }
                    continue;
                }

                // Every other command carries exactly one value byte.
                uint8_t value;
                if (read_exact(sock, &value, 1) < 0) break;
                switch (cmd) {
                case CMD_COLOR_MODE: {
                    uint32_t new_bpp = value ? 3 : 1;
                    if (new_bpp != g_bpp) {
                        if (reallocate_buffers(g_frame_w, g_frame_h, new_bpp, &decompress_buf)) {
                            LOGI("Pixel format → %s", new_bpp == 3 ? "RGB" : "greyscale");
                        } else {
                            LOGE("Pixel format change allocation failed");
                        }
                    }
                    break;
                }
                case CMD_BRIGHTNESS: call_activity("setBrightness", 1, value); break;
                case CMD_WARMTH:     call_activity("setWarmth", 1, value); break;
                case CMD_REFRESH:    call_activity("refreshScreen", 1, value); break;
                case CMD_EINK_MODE:  call_activity("setEinkMode", 1, value); break;
                default: LOGI("Ignoring unknown command 0x%02x", cmd); break;
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
                // Tiled delta — only changed 64x64 tiles. decompress_buf is scratch.
                if (!apply_tiled_delta(g_compressed_buf, payload_len, decompress_buf)) {
                    // Our frame no longer matches the Mac's base — reconnect to resync
                    // (the server sends a fresh keyframe to every new client).
                    LOGE("Bad tiled frame — reconnecting to resync");
                    break;
                }
                clock_gettime(CLOCK_MONOTONIC, &t2);
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
                    break;  // resync via reconnect + fresh keyframe
                }

                if (flags & FLAG_KEYFRAME) {
                    memcpy(g_current_frame, decompress_buf, g_buffer_size);
                } else {
                    // Every delta must be applied — the server never sends no-op deltas,
                    // and skipping one would desync us until the next keyframe.
                    apply_delta_neon(g_current_frame, decompress_buf, g_buffer_size);
                }
            }
            clock_gettime(CLOCK_MONOTONIC, &t3);
            g_last_frame_ms = now_ms();

            send_ack(sock, seq);
            publish_frame(g_current_frame, seq);

            // Notify connected only after first frame is rendered
            // (TCP connect alone doesn't mean the server is streaming)
            if (frame_count == 0) {
                notify_connection_state(1);
            }

            if (flags & FLAG_TILED) tiled_frames += 1;
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

                LOGI("FPS: %.1f | recv: %.1fms | lz4: %.1fms | delta: %.1fms | neon: %.1fms | vsync: %.1fms | %uKB %s | drops: %d | tiled: %d | overwritten: %d | total: %d",
                     fps,
                     recv_sum / stat_frames,
                     decomp_sum / stat_frames,
                     delta_sum / stat_frames,
                     neon_avg,
                     vsync_avg,
                     payload_len / 1024,
                     (flags & FLAG_KEYFRAME) ? "KF" : ((flags & FLAG_TILED) ? "tiled" : "delta"),
                     dropped_frames,
                     tiled_frames,
                     overwritten,
                     frame_count);

                stat_frames = 0;
                recv_sum = 0;
                decomp_sum = 0;
                delta_sum = 0;
                tiled_frames = 0;
                stat_start = now;
            }
        }

        if (g_sock >= 0) {
            close(g_sock);
            g_sock = -1;
        }
        // Accepted then closed without a byte: nothing serves this host (e.g. a stale USB
        // tunnel, or the Mac refused the pairing secret) — move to the next candidate.
        if (!received_any) {
            pthread_mutex_lock(&g_host_mutex); g_host_index++; pthread_mutex_unlock(&g_host_mutex);
        }
        LOGI("Disconnected, reconnecting in 1s...");

        if (g_switching) {
            // Moving to USB: keep the last frame on screen and reconnect at once
            g_switching = 0;
            LOGI("Switching to USB");
            continue;
        }

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
// The stream belongs to one activity instance at a time. Android can briefly run two
// (relaunch while the old one is still tearing down): the newest takes over, and a stop
// from the older one must not kill the newer one's stream.
static int g_threads_alive = 0;

static void stop_session(JNIEnv *env)
{
    g_running = 0;
    pthread_cond_broadcast(&g_frame_cond);
    if (g_sock >= 0) {
        shutdown(g_sock, SHUT_RDWR);
        close(g_sock);
        g_sock = -1;
    }
    if (g_threads_alive) {
        pthread_join(g_decode_thread, NULL);
        pthread_join(g_render_thread, NULL);
        g_threads_alive = 0;
    }
    if (g_window) {
        ANativeWindow_release(g_window);
        g_window = NULL;
    }
    if (g_activity) {
        (*env)->DeleteGlobalRef(env, g_activity);
        g_activity = NULL;
    }
}

JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStart(
    JNIEnv *env, jobject thiz, jobject surface, jstring host, jint port)
{
    if (g_running || g_threads_alive) {
        if (g_activity && (*env)->IsSameObject(env, thiz, g_activity) && g_running) return;
        LOGI("Taking over the stream from a previous activity instance");
        stop_session(env);
    }

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
    g_threads_alive = 1;
}

// JNI: replace the connection candidates (first entry is tried first)
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeSetHosts(
    JNIEnv *env, jobject thiz, jobjectArray hosts)
{
    (void)thiz;
    int n = (*env)->GetArrayLength(env, hosts);
    if (n > MAX_HOSTS) n = MAX_HOSTS;
    pthread_mutex_lock(&g_host_mutex);
    char current[64];
    strncpy(current, g_hosts[g_host_index < g_host_count ? g_host_index : 0], sizeof(current));
    int count = 0;
    for (int i = 0; i < n; i++) {
        jstring js = (jstring)(*env)->GetObjectArrayElement(env, hosts, i);
        if (!js) continue;
        const char *h = (*env)->GetStringUTFChars(env, js, NULL);
        strncpy(g_hosts[count], h, sizeof(g_hosts[count]) - 1);
        g_hosts[count][sizeof(g_hosts[count]) - 1] = 0;
        (*env)->ReleaseStringUTFChars(env, js, h);
        (*env)->DeleteLocalRef(env, js);
        count++;
    }
    if (count == 0) { strcpy(g_hosts[0], "127.0.0.1"); count = 1; }
    g_host_count = count;
    // Keep pointing at the same host if it is still a candidate
    g_host_index = 0;
    for (int i = 0; i < count; i++) if (strcmp(g_hosts[i], current) == 0) { g_host_index = i; break; }
    pthread_mutex_unlock(&g_host_mutex);
    LOGI("Connection candidates: %d host(s)", count);
}

// JNI: pairing secret for Wi-Fi connections (16 bytes)
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeSetToken(
    JNIEnv *env, jobject thiz, jbyteArray token)
{
    (void)thiz;
    if (!token || (*env)->GetArrayLength(env, token) != AUTH_TOKEN_LEN) { g_has_token = 0; return; }
    (*env)->GetByteArrayRegion(env, token, 0, AUTH_TOKEN_LEN, (jbyte *)g_token);
    g_has_token = 1;
}

// JNI: the USB tunnel works (Kotlin probed it) while we stream over Wi-Fi — switch to it.
// Host 0 is always 127.0.0.1.
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeSwitchToUSB(
    JNIEnv *env, jobject thiz)
{
    (void)env; (void)thiz;
    if (g_sock < 0 || is_loopback_host(g_host)) return;
    pthread_mutex_lock(&g_host_mutex);
    g_host_index = 0;
    pthread_mutex_unlock(&g_host_mutex);
    g_switching = 1;
    shutdown(g_sock, SHUT_RDWR);
}

// JNI: called from Kotlin when Surface is destroyed
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStop(
    JNIEnv *env, jobject thiz)
{
    // A newer activity instance owns the stream now — leave it alone
    if (g_activity && !(*env)->IsSameObject(env, thiz, g_activity)) {
        LOGI("Ignoring stop from a previous activity instance");
        return;
    }
    stop_session(env);
}

// JNI: called from Kotlin on surfaceChanged with actual surface dimensions.
// Some devices (Boox Palma) report rotation=LANDSCAPE but the physical
// framebuffer stays portrait — this gives us the ground truth.
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeSetSurfaceSize(
    JNIEnv *env, jobject thiz, jint width, jint height)
{
    g_surface_w = (uint32_t)width;
    g_surface_h = (uint32_t)height;
    LOGI("Surface size: %ux%u (from surfaceChanged)", g_surface_w, g_surface_h);
}

// JNI: milliseconds since the last decoded frame (-1 before the first frame).
// Polled by Kotlin to drive the e-ink "auto" waveform mode.
JNIEXPORT jlong JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeLastFrameAgeMs(
    JNIEnv *env, jobject thiz)
{
    (void)env; (void)thiz;
    int64_t last = g_last_frame_ms;
    if (last == 0) return -1;
    return (jlong)(now_ms() - last);
}
