#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <gl/GL.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ghostty.h"

#define CMUX_GHOSTTY_WAKEUP_MESSAGE (WM_APP + 1)
#define CMUX_GHOSTTY_TIMER_ID 1001

typedef struct CmuxGhosttyEmbedHost {
    HWND hwnd;
    HDC hdc;
    HGLRC glrc;
    ghostty_app_t app;
    ghostty_surface_t surface;
    char artifact_dir[MAX_PATH];
    char transcript_path[MAX_PATH];
    char report_path[MAX_PATH];
    char action_log_path[MAX_PATH];
    char command[512];
    DWORD start_tick;
    uint32_t child_exit_code;
    bool child_exit_seen;
    bool saw_title_update;
    bool should_quit;
} CmuxGhosttyEmbedHost;

typedef int (*cmux_ghostty_init_fn)(uintptr_t, char**);
typedef ghostty_config_t (*cmux_ghostty_config_new_fn)(void);
typedef void (*cmux_ghostty_config_free_fn)(ghostty_config_t);
typedef void (*cmux_ghostty_config_finalize_fn)(ghostty_config_t);
typedef ghostty_app_t (*cmux_ghostty_app_new_fn)(const ghostty_runtime_config_s*, ghostty_config_t);
typedef void (*cmux_ghostty_app_free_fn)(ghostty_app_t);
typedef void (*cmux_ghostty_app_tick_fn)(ghostty_app_t);
typedef ghostty_surface_config_s (*cmux_ghostty_surface_config_new_fn)(void);
typedef ghostty_surface_t (*cmux_ghostty_surface_new_fn)(ghostty_app_t, const ghostty_surface_config_s*);
typedef void (*cmux_ghostty_surface_free_fn)(ghostty_surface_t);
typedef void* (*cmux_ghostty_surface_userdata_fn)(ghostty_surface_t);
typedef void (*cmux_ghostty_surface_draw_fn)(ghostty_surface_t);
typedef void (*cmux_ghostty_surface_set_size_fn)(ghostty_surface_t, uint32_t, uint32_t);
typedef void (*cmux_ghostty_surface_set_content_scale_fn)(ghostty_surface_t, double, double);
typedef void (*cmux_ghostty_surface_set_focus_fn)(ghostty_surface_t, bool);
typedef bool (*cmux_ghostty_surface_process_exited_fn)(ghostty_surface_t);
typedef bool (*cmux_ghostty_surface_read_text_fn)(ghostty_surface_t, ghostty_selection_s, ghostty_text_s*);
typedef void (*cmux_ghostty_surface_free_text_fn)(ghostty_surface_t, ghostty_text_s*);

typedef struct CmuxGhosttyApi {
    HMODULE module;
    cmux_ghostty_init_fn ghostty_init;
    cmux_ghostty_config_new_fn ghostty_config_new;
    cmux_ghostty_config_free_fn ghostty_config_free;
    cmux_ghostty_config_finalize_fn ghostty_config_finalize;
    cmux_ghostty_app_new_fn ghostty_app_new;
    cmux_ghostty_app_free_fn ghostty_app_free;
    cmux_ghostty_app_tick_fn ghostty_app_tick;
    cmux_ghostty_surface_config_new_fn ghostty_surface_config_new;
    cmux_ghostty_surface_new_fn ghostty_surface_new;
    cmux_ghostty_surface_free_fn ghostty_surface_free;
    cmux_ghostty_surface_userdata_fn ghostty_surface_userdata;
    cmux_ghostty_surface_draw_fn ghostty_surface_draw;
    cmux_ghostty_surface_set_size_fn ghostty_surface_set_size;
    cmux_ghostty_surface_set_content_scale_fn ghostty_surface_set_content_scale;
    cmux_ghostty_surface_set_focus_fn ghostty_surface_set_focus;
    cmux_ghostty_surface_process_exited_fn ghostty_surface_process_exited;
    cmux_ghostty_surface_read_text_fn ghostty_surface_read_text;
    cmux_ghostty_surface_free_text_fn ghostty_surface_free_text;
} CmuxGhosttyApi;

static CmuxGhosttyApi g_api;

static void cmux_copy_string(char* dst, size_t cap, const char* src) {
    if (cap == 0) return;
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = '\0';
}

static void cmux_join_path(char* dst, size_t cap, const char* lhs, const char* rhs) {
    if (cap == 0) return;
    dst[0] = '\0';
    if (lhs == NULL || lhs[0] == '\0') {
        cmux_copy_string(dst, cap, rhs);
        return;
    }

    snprintf(dst, cap, "%s%s%s", lhs, (lhs[strlen(lhs) - 1] == '\\' || lhs[strlen(lhs) - 1] == '/') ? "" : "\\", rhs);
}

static void cmux_write_text_file(const char* path, const char* text) {
    FILE* file = NULL;
    errno_t err = fopen_s(&file, path, "wb");
    if (err != 0 || file == NULL) return;
    if (text != NULL && text[0] != '\0') fwrite(text, 1, strlen(text), file);
    fclose(file);
}

static void cmux_append_action_log(CmuxGhosttyEmbedHost* host, const char* line) {
    FILE* file = NULL;
    errno_t err = fopen_s(&file, host->action_log_path, "ab");
    if (err != 0 || file == NULL) return;
    fwrite(line, 1, strlen(line), file);
    fwrite("\r\n", 1, 2, file);
    fclose(file);
}

static void cmux_json_escape(char* dst, size_t cap, const char* src) {
    size_t out = 0;
    if (cap == 0) return;
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }

    for (size_t i = 0; src[i] != '\0' && out + 1 < cap; ++i) {
        unsigned char ch = (unsigned char)src[i];
        const char* replacement = NULL;
        switch (ch) {
            case '\\': replacement = "\\\\"; break;
            case '\"': replacement = "\\\""; break;
            case '\r': replacement = "\\r"; break;
            case '\n': replacement = "\\n"; break;
            case '\t': replacement = "\\t"; break;
            default: break;
        }

        if (replacement != NULL) {
            size_t len = strlen(replacement);
            if (out + len >= cap) break;
            memcpy(dst + out, replacement, len);
            out += len;
            continue;
        }

        if (ch < 0x20) continue;
        dst[out++] = (char)ch;
    }

    dst[out] = '\0';
}

static void cmux_write_report(CmuxGhosttyEmbedHost* host, bool transcript_ok, const char* transcript_preview) {
    char buffer[4096];
    char transcript_path_json[MAX_PATH * 2];
    char action_log_path_json[MAX_PATH * 2];
    char command_json[sizeof(host->command) * 2];
    char transcript_preview_json[1024];
    cmux_json_escape(transcript_path_json, sizeof(transcript_path_json), host->transcript_path);
    cmux_json_escape(action_log_path_json, sizeof(action_log_path_json), host->action_log_path);
    cmux_json_escape(command_json, sizeof(command_json), host->command);
    cmux_json_escape(transcript_preview_json, sizeof(transcript_preview_json), transcript_preview);
    snprintf(
        buffer,
        sizeof(buffer),
        "{\n"
        "  \"transcriptPath\": \"%s\",\n"
        "  \"actionLogPath\": \"%s\",\n"
        "  \"command\": \"%s\",\n"
        "  \"transcriptContainsExpectedMarker\": %s,\n"
        "  \"childExitSeen\": %s,\n"
        "  \"childExitCode\": %u,\n"
        "  \"sawTitleUpdate\": %s,\n"
        "  \"durationMs\": %lu,\n"
        "  \"transcriptPreview\": \"%s\"\n"
        "}\n",
        transcript_path_json,
        action_log_path_json,
        command_json,
        transcript_ok ? "true" : "false",
        host->child_exit_seen ? "true" : "false",
        host->child_exit_code,
        host->saw_title_update ? "true" : "false",
        (unsigned long)(GetTickCount() - host->start_tick),
        transcript_preview_json
    );
    cmux_write_text_file(host->report_path, buffer);
}

static FARPROC cmux_load_symbol(HMODULE module, const char* name) {
    FARPROC symbol = GetProcAddress(module, name);
    if (symbol == NULL) fprintf(stderr, "missing ghostty export: %s\n", name);
    return symbol;
}

static bool cmux_load_ghostty_api(const char* path) {
    ZeroMemory(&g_api, sizeof(g_api));
    g_api.module = LoadLibraryA(path);
    if (g_api.module == NULL) {
        fprintf(stderr, "failed to load ghostty library: %s\n", path);
        return false;
    }

    g_api.ghostty_init = (cmux_ghostty_init_fn)cmux_load_symbol(g_api.module, "ghostty_init");
    g_api.ghostty_config_new = (cmux_ghostty_config_new_fn)cmux_load_symbol(g_api.module, "ghostty_config_new");
    g_api.ghostty_config_free = (cmux_ghostty_config_free_fn)cmux_load_symbol(g_api.module, "ghostty_config_free");
    g_api.ghostty_config_finalize = (cmux_ghostty_config_finalize_fn)cmux_load_symbol(g_api.module, "ghostty_config_finalize");
    g_api.ghostty_app_new = (cmux_ghostty_app_new_fn)cmux_load_symbol(g_api.module, "ghostty_app_new");
    g_api.ghostty_app_free = (cmux_ghostty_app_free_fn)cmux_load_symbol(g_api.module, "ghostty_app_free");
    g_api.ghostty_app_tick = (cmux_ghostty_app_tick_fn)cmux_load_symbol(g_api.module, "ghostty_app_tick");
    g_api.ghostty_surface_config_new = (cmux_ghostty_surface_config_new_fn)cmux_load_symbol(g_api.module, "ghostty_surface_config_new");
    g_api.ghostty_surface_new = (cmux_ghostty_surface_new_fn)cmux_load_symbol(g_api.module, "ghostty_surface_new");
    g_api.ghostty_surface_free = (cmux_ghostty_surface_free_fn)cmux_load_symbol(g_api.module, "ghostty_surface_free");
    g_api.ghostty_surface_userdata = (cmux_ghostty_surface_userdata_fn)cmux_load_symbol(g_api.module, "ghostty_surface_userdata");
    g_api.ghostty_surface_draw = (cmux_ghostty_surface_draw_fn)cmux_load_symbol(g_api.module, "ghostty_surface_draw");
    g_api.ghostty_surface_set_size = (cmux_ghostty_surface_set_size_fn)cmux_load_symbol(g_api.module, "ghostty_surface_set_size");
    g_api.ghostty_surface_set_content_scale = (cmux_ghostty_surface_set_content_scale_fn)cmux_load_symbol(g_api.module, "ghostty_surface_set_content_scale");
    g_api.ghostty_surface_set_focus = (cmux_ghostty_surface_set_focus_fn)cmux_load_symbol(g_api.module, "ghostty_surface_set_focus");
    g_api.ghostty_surface_process_exited = (cmux_ghostty_surface_process_exited_fn)cmux_load_symbol(g_api.module, "ghostty_surface_process_exited");
    g_api.ghostty_surface_read_text = (cmux_ghostty_surface_read_text_fn)cmux_load_symbol(g_api.module, "ghostty_surface_read_text");
    g_api.ghostty_surface_free_text = (cmux_ghostty_surface_free_text_fn)cmux_load_symbol(g_api.module, "ghostty_surface_free_text");

    return g_api.ghostty_init != NULL &&
        g_api.ghostty_config_new != NULL &&
        g_api.ghostty_config_free != NULL &&
        g_api.ghostty_config_finalize != NULL &&
        g_api.ghostty_app_new != NULL &&
        g_api.ghostty_app_free != NULL &&
        g_api.ghostty_app_tick != NULL &&
        g_api.ghostty_surface_config_new != NULL &&
        g_api.ghostty_surface_new != NULL &&
        g_api.ghostty_surface_free != NULL &&
        g_api.ghostty_surface_userdata != NULL &&
        g_api.ghostty_surface_draw != NULL &&
        g_api.ghostty_surface_set_size != NULL &&
        g_api.ghostty_surface_set_content_scale != NULL &&
        g_api.ghostty_surface_set_focus != NULL &&
        g_api.ghostty_surface_process_exited != NULL &&
        g_api.ghostty_surface_read_text != NULL &&
        g_api.ghostty_surface_free_text != NULL;
}

static bool cmux_make_current(void* userdata) {
    CmuxGhosttyEmbedHost* host = (CmuxGhosttyEmbedHost*)userdata;
    return wglMakeCurrent(host->hdc, host->glrc) == TRUE;
}

static bool cmux_swap_buffers(void* userdata) {
    CmuxGhosttyEmbedHost* host = (CmuxGhosttyEmbedHost*)userdata;
    return SwapBuffers(host->hdc) == TRUE;
}

static void cmux_runtime_wakeup(void* userdata) {
    CmuxGhosttyEmbedHost* host = (CmuxGhosttyEmbedHost*)userdata;
    if (host != NULL && host->hwnd != NULL) PostMessageW(host->hwnd, CMUX_GHOSTTY_WAKEUP_MESSAGE, 0, 0);
}

static bool cmux_runtime_read_clipboard(void* userdata, ghostty_clipboard_e location, void* state) {
    (void)userdata;
    (void)location;
    (void)state;
    return false;
}

static void cmux_runtime_confirm_read_clipboard(void* userdata, const char* text, void* state, ghostty_clipboard_request_e request) {
    (void)userdata;
    (void)text;
    (void)state;
    (void)request;
}

static void cmux_runtime_write_clipboard(
    void* userdata,
    ghostty_clipboard_e location,
    const ghostty_clipboard_content_s* content,
    size_t len,
    bool confirmed
) {
    (void)userdata;
    (void)location;
    (void)content;
    (void)len;
    (void)confirmed;
}

static void cmux_runtime_close_surface(void* userdata, bool process_alive) {
    CmuxGhosttyEmbedHost* host = (CmuxGhosttyEmbedHost*)userdata;
    (void)process_alive;
    if (host != NULL && host->hwnd != NULL) {
        host->should_quit = true;
        PostMessageW(host->hwnd, WM_CLOSE, 0, 0);
    }
}

static bool cmux_runtime_action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    (void)app;
    if (target.tag != GHOSTTY_TARGET_SURFACE) return true;

    CmuxGhosttyEmbedHost* host = (CmuxGhosttyEmbedHost*)g_api.ghostty_surface_userdata(target.target.surface);
    if (host == NULL) return true;

    char line[512];
    switch (action.tag) {
        case GHOSTTY_ACTION_SET_TITLE:
            host->saw_title_update = true;
            snprintf(line, sizeof(line), "action=set_title title=%s", action.action.set_title.title != NULL ? action.action.set_title.title : "");
            cmux_append_action_log(host, line);
            return true;
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            host->child_exit_seen = true;
            host->child_exit_code = action.action.child_exited.exit_code;
            snprintf(line, sizeof(line), "action=child_exited exit_code=%u", action.action.child_exited.exit_code);
            cmux_append_action_log(host, line);
            return true;
        default:
            snprintf(line, sizeof(line), "action=%d", (int)action.tag);
            cmux_append_action_log(host, line);
            return true;
    }
}

static bool cmux_init_gl(HWND hwnd, CmuxGhosttyEmbedHost* host) {
    PIXELFORMATDESCRIPTOR pfd;
    ZeroMemory(&pfd, sizeof(pfd));
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;

    host->hdc = GetDC(hwnd);
    if (host->hdc == NULL) return false;

    int pixel_format = ChoosePixelFormat(host->hdc, &pfd);
    if (pixel_format == 0) return false;
    if (!SetPixelFormat(host->hdc, pixel_format, &pfd)) return false;

    host->glrc = wglCreateContext(host->hdc);
    if (host->glrc == NULL) return false;
    if (!wglMakeCurrent(host->hdc, host->glrc)) return false;
    return true;
}

static void cmux_shutdown_gl(CmuxGhosttyEmbedHost* host) {
    if (host->glrc != NULL) {
        wglMakeCurrent(NULL, NULL);
        wglDeleteContext(host->glrc);
        host->glrc = NULL;
    }
    if (host->hdc != NULL && host->hwnd != NULL) {
        ReleaseDC(host->hwnd, host->hdc);
        host->hdc = NULL;
    }
}

static void cmux_surface_set_client_size(CmuxGhosttyEmbedHost* host) {
    RECT rect;
    if (host->surface == NULL) return;
    if (!GetClientRect(host->hwnd, &rect)) return;
    g_api.ghostty_surface_set_size(host->surface, (uint32_t)(rect.right - rect.left), (uint32_t)(rect.bottom - rect.top));
}

static void cmux_tick_and_invalidate(CmuxGhosttyEmbedHost* host) {
    if (host->app != NULL) g_api.ghostty_app_tick(host->app);
    if (host->hwnd != NULL) InvalidateRect(host->hwnd, NULL, FALSE);
}

static LRESULT CALLBACK cmux_window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    CmuxGhosttyEmbedHost* host = (CmuxGhosttyEmbedHost*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    switch (message) {
        case WM_NCCREATE: {
            CREATESTRUCTW* create = (CREATESTRUCTW*)lparam;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)create->lpCreateParams);
            return DefWindowProcW(hwnd, message, wparam, lparam);
        }
        case WM_TIMER:
            if (host != NULL && wparam == CMUX_GHOSTTY_TIMER_ID) {
                cmux_tick_and_invalidate(host);
                return 0;
            }
            break;
        case CMUX_GHOSTTY_WAKEUP_MESSAGE:
            if (host != NULL) {
                cmux_tick_and_invalidate(host);
                return 0;
            }
            break;
        case WM_SIZE:
            if (host != NULL) {
                cmux_surface_set_client_size(host);
                return 0;
            }
            break;
        case WM_SETFOCUS:
            if (host != NULL && host->surface != NULL) {
                g_api.ghostty_surface_set_focus(host->surface, true);
                return 0;
            }
            break;
        case WM_KILLFOCUS:
            if (host != NULL && host->surface != NULL) {
                g_api.ghostty_surface_set_focus(host->surface, false);
                return 0;
            }
            break;
        case WM_PAINT:
            if (host != NULL && host->surface != NULL) {
                PAINTSTRUCT ps;
                BeginPaint(hwnd, &ps);
                EndPaint(hwnd, &ps);
                return 0;
            }
            break;
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
    }

    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static bool cmux_create_window(CmuxGhosttyEmbedHost* host, HINSTANCE instance) {
    const wchar_t* class_name = L"CmuxGhosttyEmbedSpike";
    WNDCLASSW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.lpfnWndProc = cmux_window_proc;
    wc.hInstance = instance;
    wc.lpszClassName = class_name;
    wc.hCursor = LoadCursorA(NULL, IDC_ARROW);

    if (RegisterClassW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;

    host->hwnd = CreateWindowExW(
        0,
        class_name,
        L"Ghostty Windows Embedded Spike",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, 1024, 720,
        NULL,
        NULL,
        instance,
        host
    );

    return host->hwnd != NULL;
}

static bool cmux_capture_transcript(CmuxGhosttyEmbedHost* host, bool* transcript_ok, char* preview, size_t preview_cap) {
    ghostty_text_s text;
    ZeroMemory(&text, sizeof(text));

    ghostty_selection_s selection;
    ZeroMemory(&selection, sizeof(selection));
    selection.top_left.tag = GHOSTTY_POINT_VIEWPORT;
    selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT;
    selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT;
    selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
    selection.rectangle = false;

    if (!g_api.ghostty_surface_read_text(host->surface, selection, &text)) {
        cmux_write_text_file(host->transcript_path, "");
        *transcript_ok = false;
        preview[0] = '\0';
        return false;
    }

    size_t text_len = (size_t)text.text_len;
    char* buffer = (char*)malloc(text_len + 1);
    if (buffer == NULL) {
        g_api.ghostty_surface_free_text(host->surface, &text);
        return false;
    }
    memcpy(buffer, text.text, text_len);
    buffer[text_len] = '\0';

    cmux_write_text_file(host->transcript_path, buffer);
    *transcript_ok = strstr(buffer, "embedded-libghostty-spike") != NULL;

    size_t preview_len = text_len < preview_cap - 1 ? text_len : preview_cap - 1;
    memcpy(preview, buffer, preview_len);
    preview[preview_len] = '\0';
    for (size_t i = 0; i < preview_len; ++i) {
        if (preview[i] == '\r' || preview[i] == '\n' || preview[i] == '"') preview[i] = ' ';
    }

    free(buffer);
    g_api.ghostty_surface_free_text(host->surface, &text);
    return true;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;

    CmuxGhosttyEmbedHost host;
    ZeroMemory(&host, sizeof(host));
    host.start_tick = GetTickCount();

    const char* artifact_dir = getenv("CMUX_SMOKE_ARTIFACT_DIR");
    const char* ghostty_library = getenv("CMUX_GHOSTTY_LIB");
    const char* command = getenv("CMUX_GHOSTTY_EMBED_COMMAND");

    if (artifact_dir == NULL || artifact_dir[0] == '\0') artifact_dir = ".";
    if (ghostty_library == NULL || ghostty_library[0] == '\0') ghostty_library = "libghostty.so";
    if (command == NULL || command[0] == '\0') command = "echo embedded-libghostty-spike && echo proof-line";

    if (!cmux_load_ghostty_api(ghostty_library)) return 1;

    cmux_copy_string(host.artifact_dir, sizeof(host.artifact_dir), artifact_dir);
    cmux_copy_string(host.command, sizeof(host.command), command);
    CreateDirectoryA(host.artifact_dir, NULL);
    cmux_join_path(host.transcript_path, sizeof(host.transcript_path), host.artifact_dir, "embedded-ghostty-transcript.txt");
    cmux_join_path(host.report_path, sizeof(host.report_path), host.artifact_dir, "embedded-ghostty-report.json");
    cmux_join_path(host.action_log_path, sizeof(host.action_log_path), host.artifact_dir, "embedded-ghostty-actions.log");

    char* init_argv[] = {"ghostty-embedded-spike", NULL};
    if (g_api.ghostty_init(1, init_argv) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "ghostty_init failed\n");
        return 1;
    }

    HINSTANCE instance = GetModuleHandleW(NULL);
    if (!cmux_create_window(&host, instance)) {
        fprintf(stderr, "failed to create window\n");
        return 1;
    }
    if (!cmux_init_gl(host.hwnd, &host)) {
        fprintf(stderr, "failed to initialize GL context\n");
        return 1;
    }

    ghostty_config_t config = g_api.ghostty_config_new();
    if (config == NULL) {
        fprintf(stderr, "ghostty_config_new failed\n");
        return 1;
    }
    g_api.ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime_config;
    ZeroMemory(&runtime_config, sizeof(runtime_config));
    runtime_config.userdata = &host;
    runtime_config.supports_selection_clipboard = false;
    runtime_config.wakeup_cb = cmux_runtime_wakeup;
    runtime_config.action_cb = cmux_runtime_action;
    runtime_config.read_clipboard_cb = cmux_runtime_read_clipboard;
    runtime_config.confirm_read_clipboard_cb = cmux_runtime_confirm_read_clipboard;
    runtime_config.write_clipboard_cb = cmux_runtime_write_clipboard;
    runtime_config.close_surface_cb = cmux_runtime_close_surface;

    host.app = g_api.ghostty_app_new(&runtime_config, config);
    g_api.ghostty_config_free(config);
    if (host.app == NULL) {
        fprintf(stderr, "ghostty_app_new failed\n");
        return 1;
    }

    ghostty_surface_config_s surface_config = g_api.ghostty_surface_config_new();
    surface_config.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    surface_config.platform.windows.hwnd = host.hwnd;
    surface_config.userdata = &host;
    surface_config.make_current = cmux_make_current;
    surface_config.swap_buffers = cmux_swap_buffers;
    surface_config.scale_factor = 1.0;
    surface_config.command = host.command;
    surface_config.wait_after_command = true;
    surface_config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;

    host.surface = g_api.ghostty_surface_new(host.app, &surface_config);
    if (host.surface == NULL) {
        fprintf(stderr, "ghostty_surface_new failed\n");
        g_api.ghostty_app_free(host.app);
        return 1;
    }

    cmux_surface_set_client_size(&host);
    g_api.ghostty_surface_set_content_scale(host.surface, 1.0, 1.0);
    g_api.ghostty_surface_set_focus(host.surface, true);
    SetTimer(host.hwnd, CMUX_GHOSTTY_TIMER_ID, 16, NULL);

    DWORD deadline = GetTickCount() + 6000;
    bool transcript_ok = false;
    char preview[512];
    preview[0] = '\0';

    while (!host.should_quit && GetTickCount() < deadline) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                host.should_quit = true;
                break;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        cmux_tick_and_invalidate(&host);

        if (host.surface != NULL && host.child_exit_seen && g_api.ghostty_surface_process_exited(host.surface)) {
            Sleep(200);
            cmux_tick_and_invalidate(&host);
            break;
        }

        Sleep(16);
    }

    if (host.surface != NULL) cmux_capture_transcript(&host, &transcript_ok, preview, sizeof(preview));
    cmux_write_report(&host, transcript_ok, preview);

    if (host.surface != NULL) {
        g_api.ghostty_surface_free(host.surface);
        host.surface = NULL;
    }
    if (host.app != NULL) {
        g_api.ghostty_app_free(host.app);
        host.app = NULL;
    }
    KillTimer(host.hwnd, CMUX_GHOSTTY_TIMER_ID);
    cmux_shutdown_gl(&host);
    if (host.hwnd != NULL) {
        DestroyWindow(host.hwnd);
        host.hwnd = NULL;
    }
    if (g_api.module != NULL) {
        FreeLibrary(g_api.module);
        g_api.module = NULL;
    }

    return (transcript_ok && host.child_exit_seen && host.child_exit_code == 0) ? 0 : 2;
}
