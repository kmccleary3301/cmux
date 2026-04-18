#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <BaseTsd.h>
#include <shellapi.h>
#include <gl/GL.h>

#include <algorithm>
#include <cwctype>
#include <fstream>
#include <string>
#include <vector>

#ifndef _SSIZE_T_DEFINED
typedef SSIZE_T ssize_t;
#define _SSIZE_T_DEFINED
#endif

#include "ghostty.h"

namespace {

constexpr UINT_PTR kGhosttyTickTimerId = 1001;
constexpr UINT_PTR kScenarioTimerId = 1002;
constexpr UINT_PTR kFocusAuditTimerId = 1003;
constexpr UINT_PTR kTerminalReassertTimerId = 1004;
constexpr UINT kGhosttyTickMilliseconds = 16;
constexpr UINT kScenarioTickMilliseconds = 100;
constexpr UINT kFocusAuditMilliseconds = 120;
constexpr UINT kTerminalReassertMilliseconds = 320;
constexpr UINT kTerminalSemanticsRefreshMilliseconds = 250;
constexpr UINT kMaxRuntimeMilliseconds = 12000;
constexpr UINT kWakeupMessage = WM_APP + 11;
constexpr int kSplitterWidth = 8;
constexpr int kTerminalPaneControlId = 2001;
constexpr int kSplitterControlId = 2002;
constexpr int kBrowserPaneControlId = 2003;
constexpr int kTerminalSummaryControlId = 2101;
constexpr wchar_t kShellHostWindowName[] = L"cmux Shell Host Spike";
constexpr wchar_t kTerminalPaneBaseName[] = L"cmux Terminal Pane";
constexpr wchar_t kTerminalSummaryBaseName[] = L"cmux Terminal Content Summary";
constexpr wchar_t kSplitterBaseName[] = L"cmux Splitter";
constexpr wchar_t kBrowserPaneBaseName[] = L"cmux Browser Host Pane";

enum class PaneKind {
    none,
    terminal,
    browser,
};

struct ShellHostState;

struct PaneChildContext {
    ShellHostState* host = nullptr;
    PaneKind kind = PaneKind::none;
};

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
typedef void (*cmux_ghostty_surface_set_size_fn)(ghostty_surface_t, uint32_t, uint32_t);
typedef void (*cmux_ghostty_surface_set_content_scale_fn)(ghostty_surface_t, double, double);
typedef void (*cmux_ghostty_surface_set_focus_fn)(ghostty_surface_t, bool);
typedef bool (*cmux_ghostty_surface_process_exited_fn)(ghostty_surface_t);
typedef bool (*cmux_ghostty_surface_read_text_fn)(ghostty_surface_t, ghostty_selection_s, ghostty_text_s*);
typedef void (*cmux_ghostty_surface_free_text_fn)(ghostty_surface_t, ghostty_text_s*);

struct GhosttyApi {
    HMODULE module = nullptr;
    cmux_ghostty_init_fn ghostty_init = nullptr;
    cmux_ghostty_config_new_fn ghostty_config_new = nullptr;
    cmux_ghostty_config_free_fn ghostty_config_free = nullptr;
    cmux_ghostty_config_finalize_fn ghostty_config_finalize = nullptr;
    cmux_ghostty_app_new_fn ghostty_app_new = nullptr;
    cmux_ghostty_app_free_fn ghostty_app_free = nullptr;
    cmux_ghostty_app_tick_fn ghostty_app_tick = nullptr;
    cmux_ghostty_surface_config_new_fn ghostty_surface_config_new = nullptr;
    cmux_ghostty_surface_new_fn ghostty_surface_new = nullptr;
    cmux_ghostty_surface_free_fn ghostty_surface_free = nullptr;
    cmux_ghostty_surface_userdata_fn ghostty_surface_userdata = nullptr;
    cmux_ghostty_surface_set_size_fn ghostty_surface_set_size = nullptr;
    cmux_ghostty_surface_set_content_scale_fn ghostty_surface_set_content_scale = nullptr;
    cmux_ghostty_surface_set_focus_fn ghostty_surface_set_focus = nullptr;
    cmux_ghostty_surface_process_exited_fn ghostty_surface_process_exited = nullptr;
    cmux_ghostty_surface_read_text_fn ghostty_surface_read_text = nullptr;
    cmux_ghostty_surface_free_text_fn ghostty_surface_free_text = nullptr;
};

GhosttyApi g_api {};

struct TerminalPaneState {
    HWND hwnd = nullptr;
    HWND summary_hwnd = nullptr;
    HDC hdc = nullptr;
    HGLRC glrc = nullptr;
    ghostty_surface_t surface = nullptr;
    bool surface_created = false;
    bool child_exit_seen = false;
    uint32_t child_exit_code = 0;
    bool saw_title_update = false;
    std::wstring transcript_preview;
};

struct BrowserPaneState {
    HWND hwnd = nullptr;
    HWND content_hwnd = nullptr;
    HANDLE process = nullptr;
    std::wstring helper_path;
    std::wstring report_path;
    std::wstring ready_path;
    bool controller_ready = false;
    bool navigation_completed = false;
    bool title_seen = false;
    bool source_seen = false;
    std::wstring final_title;
    std::wstring final_url;
    std::wstring content_summary;
};

struct ShellHostState {
    HWND hwnd = nullptr;
    HWND splitter_hwnd = nullptr;
    ghostty_app_t app = nullptr;
    TerminalPaneState terminal {};
    BrowserPaneState browser {};
    PaneChildContext terminal_context {};
    PaneChildContext browser_context {};
    std::wstring requested_browser_url;
    std::wstring requested_browser_title;
    std::wstring requested_browser_helper;
    std::wstring helper_path;
    std::wstring report_path;
    std::wstring transcript_path;
    std::wstring focus_log_path;
    std::wstring action_log_path;
    std::wstring requested_command;
    std::string requested_command_utf8;
    std::wstring current_browser_status = L"starting";
    PaneKind active_pane = PaneKind::none;
    DWORD start_tick = 0;
    DWORD scenario_anchor_tick = 0;
    DWORD last_transcript_refresh_tick = 0;
    bool scenario_started = false;
    bool should_quit = false;
    bool close_requested = false;
    bool manual_focus_mode = false;
    bool pmv2_enabled = false;
    bool saw_top_level_focus = false;
    bool saw_maximize = false;
    bool saw_restore = false;
    UINT initial_dpi = 0;
    UINT last_dpi = 0;
    int layout_pass_count = 0;
    int focus_transfer_count = 0;
    int keyboard_traversal_count = 0;
    int dpi_change_count = 0;
    int scenario_step = 0;
    DWORD hold_open_ms = 0;
    bool force_high_contrast = false;
    bool high_contrast_active = false;
    bool high_contrast_setting_observed = false;
    DWORD high_contrast_flags = 0;
    UINT monitor_count = 0;
    COLORREF shell_background_color = RGB(24, 24, 24);
    COLORREF pane_background_color = RGB(24, 24, 24);
    COLORREF splitter_color = RGB(90, 90, 90);
    COLORREF text_color = RGB(245, 245, 245);
    PaneKind pending_focus_audit_pane = PaneKind::none;
    std::wstring pending_focus_audit_reason;
};

std::wstring narrow_to_wide(const std::string& value) {
    if (value.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
    if (size <= 1) return {};
    std::wstring result(static_cast<size_t>(size - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size - 1);
    return result;
}

std::string wide_to_narrow(const std::wstring& value) {
    if (value.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return {};
    std::string result(static_cast<size_t>(size - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size - 1, nullptr, nullptr);
    return result;
}

std::wstring join_path(const std::wstring& left, const std::wstring& right) {
    if (left.empty()) return right;
    if (left.back() == L'\\' || left.back() == L'/') return left + right;
    return left + L"\\" + right;
}

std::string json_escape(const std::wstring& value) {
    const std::string utf8 = wide_to_narrow(value);
    std::string escaped;
    escaped.reserve(utf8.size() + 8);
    for (unsigned char ch : utf8) {
        switch (ch) {
        case '\\': escaped += "\\\\"; break;
        case '"': escaped += "\\\""; break;
        case '\b': escaped += "\\b"; break;
        case '\f': escaped += "\\f"; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            if (ch < 0x20) {
                char buffer[7];
                sprintf_s(buffer, "\\u%04x", ch);
                escaped += buffer;
            } else {
                escaped.push_back(static_cast<char>(ch));
            }
            break;
        }
    }
    return escaped;
}

void append_line(const std::wstring& path, const std::wstring& line) {
    std::ofstream out(wide_to_narrow(path), std::ios::binary | std::ios::app);
    if (!out.is_open()) return;
    out << wide_to_narrow(line) << "\r\n";
}

std::wstring trim_for_accessibility(std::wstring value, size_t max_length) {
    value.erase(std::remove(value.begin(), value.end(), L'\r'), value.end());
    value.erase(std::remove(value.begin(), value.end(), L'\n'), value.end());
    while (!value.empty() && iswspace(value.front())) value.erase(value.begin());
    while (!value.empty() && iswspace(value.back())) value.pop_back();
    if (value.size() > max_length) {
        value.resize(max_length);
        while (!value.empty() && iswspace(value.back())) value.pop_back();
        value += L"...";
    }
    return value;
}

std::wstring compose_accessible_name(const wchar_t* base_name, const std::wstring& content_detail) {
    std::wstring composed = base_name;
    const std::wstring trimmed = trim_for_accessibility(content_detail, 72);
    if (!trimmed.empty()) {
        composed += L" - ";
        composed += trimmed;
    }
    return composed;
}

void refresh_accessibility_names(ShellHostState* host) {
    if (host == nullptr) return;
    if (host->terminal.hwnd != nullptr) {
        const std::wstring terminal_detail = !host->terminal.transcript_preview.empty()
            ? host->terminal.transcript_preview
            : host->requested_command;
        SetWindowTextW(
            host->terminal.hwnd,
            compose_accessible_name(kTerminalPaneBaseName, terminal_detail).c_str()
        );
        if (host->terminal.summary_hwnd != nullptr) {
            SetWindowTextW(
                host->terminal.summary_hwnd,
                compose_accessible_name(kTerminalSummaryBaseName, terminal_detail).c_str()
            );
        }
    }
    if (host->splitter_hwnd != nullptr) {
        SetWindowTextW(host->splitter_hwnd, kSplitterBaseName);
    }
    if (host->browser.hwnd != nullptr) {
        std::wstring browser_detail = !host->browser.final_title.empty()
            ? host->browser.final_title
            : host->requested_browser_title;
        const std::wstring browser_summary = trim_for_accessibility(host->browser.content_summary, 48);
        if (!browser_summary.empty()) {
            browser_detail += L" | ";
            browser_detail += browser_summary;
        }
        SetWindowTextW(
            host->browser.hwnd,
            compose_accessible_name(kBrowserPaneBaseName, browser_detail).c_str()
        );
    }
}

bool read_text_file(const std::wstring& path, std::wstring* content) {
    if (content == nullptr) return false;
    std::ifstream in(wide_to_narrow(path), std::ios::binary);
    if (!in.is_open()) return false;
    std::string buffer((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    *content = narrow_to_wide(buffer);
    return true;
}

bool parse_ready_value(const std::wstring& content, const wchar_t* key, std::wstring* value) {
    if (value == nullptr) return false;
    const std::wstring needle = std::wstring(key) + L"=";
    const size_t start = content.find(needle);
    if (start == std::wstring::npos) return false;
    const size_t value_start = start + needle.size();
    size_t value_end = content.find_first_of(L"\r\n", value_start);
    if (value_end == std::wstring::npos) value_end = content.size();
    *value = content.substr(value_start, value_end - value_start);
    return true;
}

void trace_stage(ShellHostState* state, const wchar_t* stage) {
    if (state == nullptr) return;
    append_line(state->action_log_path, std::wstring(L"stage:") + stage);
}

void refresh_visual_state(ShellHostState* state) {
    if (state == nullptr) return;
    if (state->high_contrast_active) {
        state->shell_background_color = GetSysColor(COLOR_WINDOW);
        state->pane_background_color = GetSysColor(COLOR_WINDOW);
        state->splitter_color = GetSysColor(COLOR_HIGHLIGHT);
        state->text_color = GetSysColor(COLOR_WINDOWTEXT);
    } else {
        state->shell_background_color = RGB(24, 24, 24);
        state->pane_background_color = RGB(32, 32, 32);
        state->splitter_color = RGB(90, 90, 90);
        state->text_color = RGB(245, 245, 245);
    }
}

void update_high_contrast_state(ShellHostState* state) {
    if (state == nullptr) return;
    HIGHCONTRASTW high_contrast {};
    high_contrast.cbSize = sizeof(high_contrast);
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(high_contrast), &high_contrast, 0) == TRUE) {
        state->high_contrast_setting_observed = true;
        state->high_contrast_flags = high_contrast.dwFlags;
        state->high_contrast_active = state->force_high_contrast ||
            ((high_contrast.dwFlags & HCF_HIGHCONTRASTON) == HCF_HIGHCONTRASTON);
    } else {
        state->high_contrast_setting_observed = false;
        state->high_contrast_flags = 0;
        state->high_contrast_active = state->force_high_contrast;
    }
    refresh_visual_state(state);
}

void invalidate_shell_visuals(const ShellHostState* state) {
    if (state == nullptr) return;
    if (state->hwnd != nullptr) InvalidateRect(state->hwnd, nullptr, TRUE);
    if (state->terminal.hwnd != nullptr) InvalidateRect(state->terminal.hwnd, nullptr, TRUE);
    if (state->terminal.summary_hwnd != nullptr) InvalidateRect(state->terminal.summary_hwnd, nullptr, TRUE);
    if (state->splitter_hwnd != nullptr) InvalidateRect(state->splitter_hwnd, nullptr, TRUE);
    if (state->browser.hwnd != nullptr) InvalidateRect(state->browser.hwnd, nullptr, TRUE);
}

const wchar_t* pane_name(PaneKind kind) {
    switch (kind) {
    case PaneKind::terminal: return L"terminal";
    case PaneKind::browser: return L"browser";
    default: return L"none";
    }
}

void write_report(const ShellHostState& state, bool transcript_ok, const std::wstring& transcript_preview) {
    std::ofstream out(wide_to_narrow(state.report_path), std::ios::binary | std::ios::trunc);
    if (!out.is_open()) return;

    out
        << "{\n"
        << "  \"pmv2Enabled\": " << (state.pmv2_enabled ? "true" : "false") << ",\n"
        << "  \"terminalSurfaceCreated\": " << (state.terminal.surface_created ? "true" : "false") << ",\n"
        << "  \"browserControllerReady\": " << (state.browser.controller_ready ? "true" : "false") << ",\n"
        << "  \"browserNavigationCompleted\": " << (state.browser.navigation_completed ? "true" : "false") << ",\n"
        << "  \"browserTitleSeen\": " << (state.browser.title_seen ? "true" : "false") << ",\n"
        << "  \"browserSourceSeen\": " << (state.browser.source_seen ? "true" : "false") << ",\n"
        << "  \"focusTransferCount\": " << state.focus_transfer_count << ",\n"
        << "  \"keyboardTraversalCount\": " << state.keyboard_traversal_count << ",\n"
        << "  \"layoutPassCount\": " << state.layout_pass_count << ",\n"
        << "  \"maximizeRoundTripSeen\": " << ((state.saw_maximize && state.saw_restore) ? "true" : "false") << ",\n"
        << "  \"initialDpi\": " << state.initial_dpi << ",\n"
        << "  \"lastDpi\": " << state.last_dpi << ",\n"
        << "  \"dpiChangeCount\": " << state.dpi_change_count << ",\n"
        << "  \"monitorCount\": " << state.monitor_count << ",\n"
        << "  \"highContrastActive\": " << (state.high_contrast_active ? "true" : "false") << ",\n"
        << "  \"highContrastForced\": " << (state.force_high_contrast ? "true" : "false") << ",\n"
        << "  \"highContrastSettingObserved\": " << (state.high_contrast_setting_observed ? "true" : "false") << ",\n"
        << "  \"highContrastFlags\": " << state.high_contrast_flags << ",\n"
        << "  \"shellBackgroundColor\": " << state.shell_background_color << ",\n"
        << "  \"paneBackgroundColor\": " << state.pane_background_color << ",\n"
        << "  \"splitterColor\": " << state.splitter_color << ",\n"
        << "  \"textColor\": " << state.text_color << ",\n"
        << "  \"sawTopLevelFocus\": " << (state.saw_top_level_focus ? "true" : "false") << ",\n"
        << "  \"splitterHostCreated\": " << (state.splitter_hwnd != nullptr ? "true" : "false") << ",\n"
        << "  \"activePaneAtExit\": \"" << json_escape(pane_name(state.active_pane)) << "\",\n"
        << "  \"browserFinalTitle\": \"" << json_escape(state.browser.final_title) << "\",\n"
        << "  \"browserFinalURL\": \"" << json_escape(state.browser.final_url) << "\",\n"
        << "  \"browserContentSummary\": \"" << json_escape(state.browser.content_summary) << "\",\n"
        << "  \"terminalContentSummary\": \"" << json_escape(compose_accessible_name(
            kTerminalSummaryBaseName,
            !transcript_preview.empty() ? transcript_preview : state.requested_command
        )) << "\",\n"
        << "  \"browserStatus\": \"" << json_escape(state.current_browser_status) << "\",\n"
        << "  \"transcriptPath\": \"" << json_escape(state.transcript_path) << "\",\n"
        << "  \"focusLogPath\": \"" << json_escape(state.focus_log_path) << "\",\n"
        << "  \"actionLogPath\": \"" << json_escape(state.action_log_path) << "\",\n"
        << "  \"transcriptContainsExpectedMarker\": " << (transcript_ok ? "true" : "false") << ",\n"
        << "  \"childExitSeen\": " << (state.terminal.child_exit_seen ? "true" : "false") << ",\n"
        << "  \"childExitCode\": " << state.terminal.child_exit_code << ",\n"
        << "  \"requestedCommand\": \"" << json_escape(state.requested_command) << "\",\n"
        << "  \"requestedBrowserURL\": \"" << json_escape(state.requested_browser_url) << "\",\n"
        << "  \"requestedBrowserTitle\": \"" << json_escape(state.requested_browser_title) << "\",\n"
        << "  \"helperPath\": \"" << json_escape(state.helper_path) << "\",\n"
        << "  \"durationMs\": " << (GetTickCount() - state.start_tick) << ",\n"
        << "  \"transcriptPreview\": \"" << json_escape(transcript_preview) << "\"\n"
        << "}\n";
}

bool is_browser_focus_true(const ShellHostState* host, HWND focused) {
    if (host == nullptr) return false;
    bool browser_focused = focused == host->browser.hwnd || IsChild(host->browser.hwnd, focused);
    if (!browser_focused && host->browser.content_hwnd != nullptr) {
        GUITHREADINFO browser_info {};
        browser_info.cbSize = sizeof(browser_info);
        const DWORD browser_thread = GetWindowThreadProcessId(host->browser.content_hwnd, nullptr);
        if (browser_thread != 0 && GetGUIThreadInfo(browser_thread, &browser_info)) {
            const HWND browser_hwnd = browser_info.hwndFocus != nullptr ? browser_info.hwndFocus : browser_info.hwndActive;
            browser_focused =
                browser_hwnd == host->browser.content_hwnd ||
                browser_hwnd == host->browser.hwnd ||
                IsChild(host->browser.hwnd, browser_hwnd);
        }
    }
    return browser_focused;
}

void append_focus_observation(ShellHostState* host, PaneKind pane, const wchar_t* reason, bool delayed) {
    if (host == nullptr) return;

    std::wstring line = L"focus=";
    line += pane_name(pane);
    line += L" reason=";
    line += reason != nullptr ? reason : L"unknown";
    if (delayed) {
        line += L" delayed=true";
    }
    line += L" actual=";

    const HWND shell_focus = GetFocus();
    GUITHREADINFO info {};
    info.cbSize = sizeof(info);
    GetGUIThreadInfo(0, &info);
    HWND focused = info.hwndFocus;

    GUITHREADINFO browser_info {};
    browser_info.cbSize = sizeof(browser_info);
    HWND browser_thread_focus = nullptr;
    if (host->browser.content_hwnd != nullptr) {
        const DWORD browser_thread = GetWindowThreadProcessId(host->browser.content_hwnd, nullptr);
        if (browser_thread != 0 && GetGUIThreadInfo(browser_thread, &browser_info)) {
            browser_thread_focus = browser_info.hwndFocus != nullptr ? browser_info.hwndFocus : browser_info.hwndActive;
        }
    }

    if (pane == PaneKind::terminal) {
        line += (shell_focus == host->terminal.hwnd || IsChild(host->terminal.hwnd, shell_focus)) ? L"true" : L"false";
    } else {
        line += is_browser_focus_true(host, focused) ? L"true" : L"false";
    }
    wchar_t shell_buffer[32] {};
    wchar_t gui_buffer[32] {};
    wchar_t browser_buffer[32] {};
    swprintf_s(shell_buffer, L"0x%p", shell_focus);
    swprintf_s(gui_buffer, L"0x%p", focused);
    swprintf_s(browser_buffer, L"0x%p", browser_thread_focus);
    line += L" shellFocus=";
    line += shell_buffer;
    line += L" guiFocus=";
    line += gui_buffer;
    line += L" browserThreadFocus=";
    line += browser_buffer;
    append_line(host->focus_log_path, line);
}

void set_focus_with_browser_thread(HWND owner, HWND target, HWND browser_content_hwnd) {
    const DWORD current_thread = GetCurrentThreadId();
    DWORD browser_thread = 0;
    if (browser_content_hwnd != nullptr) {
        browser_thread = GetWindowThreadProcessId(browser_content_hwnd, nullptr);
    }

    const bool attached = browser_thread != 0 &&
        browser_thread != current_thread &&
        AttachThreadInput(current_thread, browser_thread, TRUE) == TRUE;

    if (owner != nullptr) {
        BringWindowToTop(owner);
        SetForegroundWindow(owner);
        SetActiveWindow(owner);
        SetFocus(owner);
    }
    SetFocus(target);

    if (attached) {
        AttachThreadInput(current_thread, browser_thread, FALSE);
    }
}

FARPROC load_symbol(HMODULE module, const char* name) {
    FARPROC symbol = GetProcAddress(module, name);
    if (symbol == nullptr) fprintf(stderr, "missing ghostty export: %s\n", name);
    return symbol;
}

bool load_ghostty_api(const char* path) {
    g_api = {};
    g_api.module = LoadLibraryA(path);
    if (g_api.module == nullptr) {
        fprintf(stderr, "failed to load ghostty library: %s\n", path);
        return false;
    }

    g_api.ghostty_init = reinterpret_cast<cmux_ghostty_init_fn>(load_symbol(g_api.module, "ghostty_init"));
    g_api.ghostty_config_new = reinterpret_cast<cmux_ghostty_config_new_fn>(load_symbol(g_api.module, "ghostty_config_new"));
    g_api.ghostty_config_free = reinterpret_cast<cmux_ghostty_config_free_fn>(load_symbol(g_api.module, "ghostty_config_free"));
    g_api.ghostty_config_finalize = reinterpret_cast<cmux_ghostty_config_finalize_fn>(load_symbol(g_api.module, "ghostty_config_finalize"));
    g_api.ghostty_app_new = reinterpret_cast<cmux_ghostty_app_new_fn>(load_symbol(g_api.module, "ghostty_app_new"));
    g_api.ghostty_app_free = reinterpret_cast<cmux_ghostty_app_free_fn>(load_symbol(g_api.module, "ghostty_app_free"));
    g_api.ghostty_app_tick = reinterpret_cast<cmux_ghostty_app_tick_fn>(load_symbol(g_api.module, "ghostty_app_tick"));
    g_api.ghostty_surface_config_new = reinterpret_cast<cmux_ghostty_surface_config_new_fn>(load_symbol(g_api.module, "ghostty_surface_config_new"));
    g_api.ghostty_surface_new = reinterpret_cast<cmux_ghostty_surface_new_fn>(load_symbol(g_api.module, "ghostty_surface_new"));
    g_api.ghostty_surface_free = reinterpret_cast<cmux_ghostty_surface_free_fn>(load_symbol(g_api.module, "ghostty_surface_free"));
    g_api.ghostty_surface_userdata = reinterpret_cast<cmux_ghostty_surface_userdata_fn>(load_symbol(g_api.module, "ghostty_surface_userdata"));
    g_api.ghostty_surface_set_size = reinterpret_cast<cmux_ghostty_surface_set_size_fn>(load_symbol(g_api.module, "ghostty_surface_set_size"));
    g_api.ghostty_surface_set_content_scale = reinterpret_cast<cmux_ghostty_surface_set_content_scale_fn>(load_symbol(g_api.module, "ghostty_surface_set_content_scale"));
    g_api.ghostty_surface_set_focus = reinterpret_cast<cmux_ghostty_surface_set_focus_fn>(load_symbol(g_api.module, "ghostty_surface_set_focus"));
    g_api.ghostty_surface_process_exited = reinterpret_cast<cmux_ghostty_surface_process_exited_fn>(load_symbol(g_api.module, "ghostty_surface_process_exited"));
    g_api.ghostty_surface_read_text = reinterpret_cast<cmux_ghostty_surface_read_text_fn>(load_symbol(g_api.module, "ghostty_surface_read_text"));
    g_api.ghostty_surface_free_text = reinterpret_cast<cmux_ghostty_surface_free_text_fn>(load_symbol(g_api.module, "ghostty_surface_free_text"));

    return g_api.ghostty_init != nullptr &&
        g_api.ghostty_config_new != nullptr &&
        g_api.ghostty_config_free != nullptr &&
        g_api.ghostty_config_finalize != nullptr &&
        g_api.ghostty_app_new != nullptr &&
        g_api.ghostty_app_free != nullptr &&
        g_api.ghostty_app_tick != nullptr &&
        g_api.ghostty_surface_config_new != nullptr &&
        g_api.ghostty_surface_new != nullptr &&
        g_api.ghostty_surface_free != nullptr &&
        g_api.ghostty_surface_userdata != nullptr &&
        g_api.ghostty_surface_set_size != nullptr &&
        g_api.ghostty_surface_set_content_scale != nullptr &&
        g_api.ghostty_surface_set_focus != nullptr &&
        g_api.ghostty_surface_process_exited != nullptr &&
        g_api.ghostty_surface_read_text != nullptr &&
        g_api.ghostty_surface_free_text != nullptr;
}

bool ghostty_make_current(void* userdata) {
    auto* host = reinterpret_cast<ShellHostState*>(userdata);
    return host != nullptr && wglMakeCurrent(host->terminal.hdc, host->terminal.glrc) == TRUE;
}

bool ghostty_swap_buffers(void* userdata) {
    auto* host = reinterpret_cast<ShellHostState*>(userdata);
    return host != nullptr && SwapBuffers(host->terminal.hdc) == TRUE;
}

void ghostty_wakeup(void* userdata) {
    auto* host = reinterpret_cast<ShellHostState*>(userdata);
    if (host != nullptr && host->hwnd != nullptr) PostMessageW(host->hwnd, kWakeupMessage, 0, 0);
}

bool ghostty_read_clipboard(void* userdata, ghostty_clipboard_e, void*) {
    (void)userdata;
    return false;
}

void ghostty_confirm_read_clipboard(void*, const char*, void*, ghostty_clipboard_request_e) {}

void ghostty_write_clipboard(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool) {}

void ghostty_close_surface(void* userdata, bool) {
    auto* host = reinterpret_cast<ShellHostState*>(userdata);
    if (host != nullptr) {
        host->should_quit = true;
        host->close_requested = true;
        trace_stage(host, L"ghostty-close-requested");
    }
}

bool ghostty_action(ghostty_app_t, ghostty_target_s target, ghostty_action_s action) {
    if (target.tag != GHOSTTY_TARGET_SURFACE) return true;
    auto* host = reinterpret_cast<ShellHostState*>(g_api.ghostty_surface_userdata(target.target.surface));
    if (host == nullptr) return true;

    switch (action.tag) {
    case GHOSTTY_ACTION_SET_TITLE:
        host->terminal.saw_title_update = true;
        append_line(host->action_log_path, L"ghostty:set-title");
        return true;
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        host->terminal.child_exit_seen = true;
        host->terminal.child_exit_code = action.action.child_exited.exit_code;
        append_line(host->action_log_path, L"ghostty:child-exited");
        return true;
    default:
        return true;
    }
}

void update_terminal_size(ShellHostState* host) {
    if (host == nullptr || host->terminal.surface == nullptr || host->terminal.hwnd == nullptr) return;
    RECT rect {};
    if (!GetClientRect(host->terminal.hwnd, &rect)) return;
    g_api.ghostty_surface_set_size(
        host->terminal.surface,
        static_cast<uint32_t>(rect.right - rect.left),
        static_cast<uint32_t>(rect.bottom - rect.top)
    );
}

void set_active_pane(ShellHostState* host, PaneKind pane, const wchar_t* reason);
void refresh_terminal_summary_from_live_transcript(ShellHostState* host, bool force);

void layout_children(ShellHostState* host) {
    if (host == nullptr || host->hwnd == nullptr || host->terminal.hwnd == nullptr || host->browser.hwnd == nullptr) return;

    RECT rect {};
    if (!GetClientRect(host->hwnd, &rect)) return;

    const int width = rect.right - rect.left;
    const int height = rect.bottom - rect.top;
    const int split = width / 2;
    const int left_width = std::max(0, split - (kSplitterWidth / 2));
    const int splitter_x = left_width;
    const int right_x = splitter_x + kSplitterWidth;
    const int right_width = std::max(0, width - right_x);

    MoveWindow(host->terminal.hwnd, 0, 0, left_width, height, TRUE);
    if (host->splitter_hwnd != nullptr) {
        MoveWindow(host->splitter_hwnd, splitter_x, 0, kSplitterWidth, height, TRUE);
    }
    MoveWindow(host->browser.hwnd, right_x, 0, right_width, height, TRUE);
    if (host->browser.content_hwnd != nullptr) {
        MoveWindow(host->browser.content_hwnd, 0, 0, right_width, height, TRUE);
    }
    update_terminal_size(host);
    refresh_accessibility_names(host);

    host->layout_pass_count += 1;
}

void layout_terminal_summary_child(ShellHostState* host) {
    if (host == nullptr || host->terminal.hwnd == nullptr || host->terminal.summary_hwnd == nullptr) return;

    RECT rect {};
    if (!GetClientRect(host->terminal.hwnd, &rect)) return;

    const int width = std::max(0, static_cast<int>(rect.right - rect.left));
    const int child_x = 8;
    const int child_y = 8;
    const int child_width = std::max(0, width - 16);
    const int child_height = 22;
    MoveWindow(host->terminal.summary_hwnd, child_x, child_y, child_width, child_height, TRUE);
}

void cycle_focus(ShellHostState* host, const wchar_t* reason) {
    if (host == nullptr) return;
    const PaneKind next = host->active_pane == PaneKind::browser ? PaneKind::terminal : PaneKind::browser;
    host->keyboard_traversal_count += 1;
    set_active_pane(host, next, reason);
}

void tick_ghostty(ShellHostState* host) {
    if (host != nullptr && host->app != nullptr) {
        g_api.ghostty_app_tick(host->app);
        if (host->terminal.hwnd != nullptr) InvalidateRect(host->terminal.hwnd, nullptr, FALSE);
    }
}

void set_active_pane(ShellHostState* host, PaneKind pane, const wchar_t* reason) {
    if (host == nullptr || pane == PaneKind::none || host->active_pane == pane) return;

    host->active_pane = pane;
    host->focus_transfer_count += 1;

    if (host->hwnd != nullptr) {
        SetActiveWindow(host->hwnd);
    }

    if (host->terminal.surface != nullptr) {
        g_api.ghostty_surface_set_focus(host->terminal.surface, pane == PaneKind::terminal);
    }

    if (host->browser.hwnd != nullptr) {
        EnableWindow(host->browser.hwnd, pane == PaneKind::browser ? TRUE : FALSE);
    }
    if (host->browser.content_hwnd != nullptr) {
        EnableWindow(host->browser.content_hwnd, pane == PaneKind::browser ? TRUE : FALSE);
    }

    if (pane == PaneKind::terminal && host->terminal.hwnd != nullptr) {
        set_focus_with_browser_thread(host->hwnd, host->terminal.hwnd, host->browser.content_hwnd);
    } else if (pane == PaneKind::browser) {
        if (host->browser.hwnd != nullptr) {
            SetFocus(host->browser.hwnd);
        }
    }

    {
        std::wstring debug = L"set-focus pane=";
        debug += pane_name(pane);
        debug += L" reason=";
        debug += reason != nullptr ? reason : L"unknown";
        debug += L" getfocus=";
        const HWND focus_hwnd = GetFocus();
        wchar_t buffer[32] {};
        swprintf_s(buffer, L"0x%p", focus_hwnd);
        debug += buffer;
        append_line(host->action_log_path, debug);
    }

    append_focus_observation(host, pane, reason, false);
    if (host->hwnd != nullptr) {
        host->pending_focus_audit_pane = pane;
        host->pending_focus_audit_reason = reason != nullptr ? reason : L"unknown";
        SetTimer(host->hwnd, kFocusAuditTimerId, kFocusAuditMilliseconds, nullptr);
        if (pane == PaneKind::terminal) {
            SetTimer(host->hwnd, kTerminalReassertTimerId, kTerminalReassertMilliseconds, nullptr);
        } else {
            KillTimer(host->hwnd, kTerminalReassertTimerId);
        }
    }
}

bool launch_browser_helper(ShellHostState* host) {
    if (host == nullptr || host->browser.hwnd == nullptr || host->requested_browser_helper.empty()) return false;
    trace_stage(host, L"browser-helper-start");

    host->browser.helper_path = host->requested_browser_helper;
    const auto report_dir = host->report_path.substr(0, host->report_path.find_last_of(L"\\/"));
    host->browser.report_path = join_path(report_dir, L"shell-host-browser-report.json");
    host->browser.ready_path = join_path(report_dir, L"shell-host-browser-ready.txt");

    DeleteFileW(host->browser.report_path.c_str());
    DeleteFileW(host->browser.ready_path.c_str());

    wchar_t parent_hwnd_buffer[32] {};
    swprintf_s(parent_hwnd_buffer, L"0x%p", host->browser.hwnd);

    std::wstring command_line =
        L"\"" + host->requested_browser_helper + L"\""
        L" --parent-hwnd " + std::wstring(parent_hwnd_buffer) +
        L" --url \"" + host->requested_browser_url + L"\"" +
        L" --title \"" + host->requested_browser_title + L"\"" +
        L" --report \"" + host->browser.report_path + L"\"" +
        L" --ready-file \"" + host->browser.ready_path + L"\"";

    STARTUPINFOW startup_info {};
    startup_info.cb = sizeof(startup_info);
    PROCESS_INFORMATION process_info {};

    std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');

    const BOOL created = CreateProcessW(
        nullptr,
        mutable_command.data(),
        nullptr,
        nullptr,
        FALSE,
        0,
        nullptr,
        nullptr,
        &startup_info,
        &process_info
    );
    if (created != TRUE) {
        append_line(host->action_log_path, L"browser-helper-launch-failed");
        return false;
    }

    CloseHandle(process_info.hThread);
    host->browser.process = process_info.hProcess;
    append_line(host->action_log_path, L"browser-helper-launch-ready");
    return true;
}

void poll_browser_helper_ready(ShellHostState* host) {
    if (host == nullptr) return;
    if (host->browser.process != nullptr) {
        DWORD process_exit = STILL_ACTIVE;
        if (GetExitCodeProcess(host->browser.process, &process_exit) && process_exit != STILL_ACTIVE) {
            host->current_browser_status = L"helper-exited";
            return;
        }
    }

    std::wstring ready_contents;
    if (!read_text_file(host->browser.ready_path, &ready_contents)) return;

    std::wstring ready_flag;
    std::wstring hwnd_value;
    std::wstring title_value;
    std::wstring url_value;
    std::wstring summary_value;
    if (!parse_ready_value(ready_contents, L"ready", &ready_flag)) return;
    if (ready_flag != L"true") return;

    parse_ready_value(ready_contents, L"hwnd", &hwnd_value);
    parse_ready_value(ready_contents, L"title", &title_value);
    parse_ready_value(ready_contents, L"url", &url_value);
    parse_ready_value(ready_contents, L"summary", &summary_value);

    if (!host->browser.controller_ready && !hwnd_value.empty()) {
        const unsigned long long parsed = _wcstoui64(hwnd_value.c_str(), nullptr, 0);
        host->browser.content_hwnd = reinterpret_cast<HWND>(static_cast<uintptr_t>(parsed));
    }

    const bool initial_ready = !host->browser.controller_ready;
    host->browser.controller_ready = true;
    host->browser.navigation_completed = true;
    host->browser.title_seen = !title_value.empty();
    host->browser.source_seen = !url_value.empty();
    host->browser.final_title = title_value;
    host->browser.final_url = url_value;
    host->browser.content_summary = summary_value;
    host->current_browser_status = L"webview2-ready";
    if (initial_ready) {
        trace_stage(host, L"browser-helper-ready");
    }
    refresh_accessibility_names(host);
    layout_children(host);
}

void maybe_advance_scenario(ShellHostState* host) {
    if (host == nullptr) return;
    poll_browser_helper_ready(host);
    refresh_terminal_summary_from_live_transcript(host, false);

    const bool ready =
        host->terminal.surface_created &&
        host->browser.controller_ready &&
        host->browser.navigation_completed;

    if (!host->scenario_started) {
        if (!ready) return;
        host->scenario_started = true;
        host->scenario_anchor_tick = GetTickCount();
        host->scenario_step = 0;
        if (host->manual_focus_mode) {
            set_active_pane(host, PaneKind::terminal, L"manual-initial");
        }
    }

    const DWORD elapsed = GetTickCount() - host->scenario_anchor_tick;
    if (host->manual_focus_mode) {
        if (host->scenario_step == 0 && elapsed >= 1500) {
            ShowWindow(host->hwnd, SW_MAXIMIZE);
            host->saw_maximize = true;
            host->scenario_step = 1;
        } else if (host->scenario_step == 1 && elapsed >= 2300) {
            ShowWindow(host->hwnd, SW_RESTORE);
            SetWindowPos(host->hwnd, nullptr, 0, 0, 1320, 820, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            host->saw_restore = true;
            host->scenario_step = 2;
        } else if (host->scenario_step == 2 && elapsed >= 3200 && host->terminal.child_exit_seen && host->keyboard_traversal_count >= 2) {
            set_active_pane(host, PaneKind::browser, L"manual-pre-close");
            host->scenario_step = 3;
        } else if (host->scenario_step == 3 && elapsed >= (3600 + host->hold_open_ms)) {
            host->should_quit = true;
            host->close_requested = true;
            trace_stage(host, L"scenario-close-requested");
            host->scenario_step = 4;
        }
        return;
    }

    if (host->scenario_step == 0 && elapsed >= 300) {
        set_active_pane(host, PaneKind::terminal, L"scenario-terminal-initial");
        host->scenario_step = 1;
    } else if (host->scenario_step == 1 && elapsed >= 900) {
        set_active_pane(host, PaneKind::browser, L"scenario-browser");
        host->scenario_step = 2;
    } else if (host->scenario_step == 2 && elapsed >= 1500) {
        ShowWindow(host->hwnd, SW_MAXIMIZE);
        host->saw_maximize = true;
        host->scenario_step = 3;
    } else if (host->scenario_step == 3 && elapsed >= 2200) {
        ShowWindow(host->hwnd, SW_RESTORE);
        SetWindowPos(host->hwnd, nullptr, 0, 0, 1320, 820, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        host->saw_restore = true;
        host->scenario_step = 4;
    } else if (host->scenario_step == 4 && elapsed >= 2900) {
        set_active_pane(host, PaneKind::terminal, L"scenario-terminal-final");
        host->scenario_step = 5;
    } else if (host->scenario_step == 5 && elapsed >= (3600 + host->hold_open_ms) && host->terminal.child_exit_seen) {
        host->should_quit = true;
        host->close_requested = true;
        trace_stage(host, L"scenario-close-requested");
        host->scenario_step = 6;
    }
}

bool initialize_browser_helper_host(ShellHostState* host) {
    if (host == nullptr) return false;
    if (!launch_browser_helper(host)) {
        host->current_browser_status = L"launch-failed";
        return false;
    }
    host->current_browser_status = L"starting";
    return true;
}

bool initialize_terminal_gl(ShellHostState* host) {
    trace_stage(host, L"terminal-gl-start");
    PIXELFORMATDESCRIPTOR pfd {};
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;

    host->terminal.hdc = GetDC(host->terminal.hwnd);
    if (host->terminal.hdc == nullptr) return false;

    int pixel_format = ChoosePixelFormat(host->terminal.hdc, &pfd);
    if (pixel_format == 0) return false;
    if (!SetPixelFormat(host->terminal.hdc, pixel_format, &pfd)) return false;

    host->terminal.glrc = wglCreateContext(host->terminal.hdc);
    if (host->terminal.glrc == nullptr) return false;
    if (!wglMakeCurrent(host->terminal.hdc, host->terminal.glrc)) return false;
    trace_stage(host, L"terminal-gl-ready");
    return true;
}

void shutdown_terminal_gl(ShellHostState* host) {
    if (host == nullptr) return;
    if (host->terminal.glrc != nullptr) {
        wglMakeCurrent(nullptr, nullptr);
        wglDeleteContext(host->terminal.glrc);
        host->terminal.glrc = nullptr;
    }
    if (host->terminal.hdc != nullptr && host->terminal.hwnd != nullptr) {
        ReleaseDC(host->terminal.hwnd, host->terminal.hdc);
        host->terminal.hdc = nullptr;
    }
}

bool initialize_terminal_surface(ShellHostState* host) {
    trace_stage(host, L"terminal-surface-start");
    ghostty_config_t config = g_api.ghostty_config_new();
    if (config == nullptr) return false;
    g_api.ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime_config {};
    runtime_config.userdata = host;
    runtime_config.supports_selection_clipboard = false;
    runtime_config.wakeup_cb = ghostty_wakeup;
    runtime_config.action_cb = ghostty_action;
    runtime_config.read_clipboard_cb = ghostty_read_clipboard;
    runtime_config.confirm_read_clipboard_cb = ghostty_confirm_read_clipboard;
    runtime_config.write_clipboard_cb = ghostty_write_clipboard;
    runtime_config.close_surface_cb = ghostty_close_surface;

    host->app = g_api.ghostty_app_new(&runtime_config, config);
    g_api.ghostty_config_free(config);
    if (host->app == nullptr) return false;
    trace_stage(host, L"ghostty-app-ready");

    ghostty_surface_config_s surface_config = g_api.ghostty_surface_config_new();
    surface_config.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    surface_config.platform.windows.hwnd = host->terminal.hwnd;
    surface_config.userdata = host;
    surface_config.make_current = ghostty_make_current;
    surface_config.swap_buffers = ghostty_swap_buffers;
    surface_config.scale_factor = 1.0;
    surface_config.command = host->requested_command_utf8.c_str();
    surface_config.wait_after_command = true;
    surface_config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;

    host->terminal.surface = g_api.ghostty_surface_new(host->app, &surface_config);
    if (host->terminal.surface == nullptr) return false;

    host->terminal.surface_created = true;
    trace_stage(host, L"terminal-surface-ready");
    update_terminal_size(host);
    g_api.ghostty_surface_set_content_scale(host->terminal.surface, 1.0, 1.0);
    g_api.ghostty_surface_set_focus(host->terminal.surface, false);
    return true;
}

bool capture_terminal_transcript(ShellHostState* host, bool* transcript_ok, std::wstring* transcript_preview) {
    ghostty_selection_s selection {};
    selection.top_left.tag = GHOSTTY_POINT_VIEWPORT;
    selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT;
    selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT;
    selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
    selection.rectangle = false;

    std::string last_buffer;
    bool read_any_text = false;

    for (int attempt = 0; attempt < 20; ++attempt) {
        ghostty_text_s text {};
        if (g_api.ghostty_surface_read_text(host->terminal.surface, selection, &text)) {
            read_any_text = true;
            const size_t text_len = static_cast<size_t>(text.text_len);
            last_buffer.assign(text.text, text.text + text_len);
            g_api.ghostty_surface_free_text(host->terminal.surface, &text);

            if (last_buffer.find("shell-host-spike") != std::string::npos) {
                break;
            }
        }

        Sleep(120);
    }

    std::ofstream out(wide_to_narrow(host->transcript_path), std::ios::binary | std::ios::trunc);
    if (out.is_open()) out.write(last_buffer.data(), static_cast<std::streamsize>(last_buffer.size()));
    *transcript_ok = last_buffer.find("shell-host-spike") != std::string::npos;

    std::string preview = last_buffer.substr(0, 240);
    for (char& ch : preview) {
        if (ch == '\r' || ch == '\n' || ch == '"') ch = ' ';
    }
    *transcript_preview = narrow_to_wide(preview);
    host->terminal.transcript_preview = *transcript_preview;
    refresh_accessibility_names(host);

    return read_any_text;
}

void refresh_terminal_summary_from_live_transcript(ShellHostState* host, bool force) {
    if (host == nullptr || host->terminal.surface == nullptr) return;

    const DWORD now = GetTickCount();
    if (!force && host->last_transcript_refresh_tick != 0 &&
        now - host->last_transcript_refresh_tick < kTerminalSemanticsRefreshMilliseconds) {
        return;
    }
    host->last_transcript_refresh_tick = now;

    ghostty_selection_s selection {};
    selection.top_left.tag = GHOSTTY_POINT_VIEWPORT;
    selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT;
    selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT;
    selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
    selection.rectangle = false;

    ghostty_text_s text {};
    if (!g_api.ghostty_surface_read_text(host->terminal.surface, selection, &text)) return;

    const size_t text_len = static_cast<size_t>(text.text_len);
    std::string buffer(text.text, text.text + text_len);
    g_api.ghostty_surface_free_text(host->terminal.surface, &text);

    if (buffer.empty()) return;

    std::string preview = buffer.substr(0, 240);
    for (char& ch : preview) {
        if (ch == '\r' || ch == '\n' || ch == '"') ch = ' ';
    }

    const std::wstring next_preview = narrow_to_wide(preview);
    if (next_preview.empty() || next_preview == host->terminal.transcript_preview) return;

    host->terminal.transcript_preview = next_preview;
    refresh_accessibility_names(host);
}

LRESULT CALLBACK terminal_child_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* context = reinterpret_cast<PaneChildContext*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    auto* host = context != nullptr ? context->host : nullptr;

    switch (message) {
    case WM_NCCREATE: {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    case WM_SIZE:
        update_terminal_size(host);
        if (host != nullptr) layout_terminal_summary_child(host);
        return 0;
    case WM_SETFOCUS:
        if (host != nullptr && host->terminal.surface != nullptr) {
            g_api.ghostty_surface_set_focus(host->terminal.surface, true);
            append_line(host->action_log_path, L"terminal:wm-setfocus");
        }
        return 0;
    case WM_KILLFOCUS:
        if (host != nullptr && host->terminal.surface != nullptr) {
            g_api.ghostty_surface_set_focus(host->terminal.surface, false);
            append_line(host->action_log_path, L"terminal:wm-killfocus");
        }
        return 0;
    case WM_LBUTTONDOWN:
        if (host != nullptr) set_active_pane(host, PaneKind::terminal, L"mouse-click");
        return 0;
    case WM_KEYDOWN:
        if (host != nullptr && (wparam == VK_F6 || wparam == VK_TAB)) {
            cycle_focus(host, L"keyboard-cycle");
            return 0;
        }
        break;
    case WM_GETDLGCODE:
        return DLGC_WANTTAB | DLGC_WANTARROWS;
    case WM_CTLCOLORSTATIC:
        if (host != nullptr && reinterpret_cast<HWND>(lparam) == host->terminal.summary_hwnd) {
            HDC hdc = reinterpret_cast<HDC>(wparam);
            SetTextColor(hdc, host->text_color);
            SetBkMode(hdc, TRANSPARENT);
            return reinterpret_cast<INT_PTR>(GetStockObject(NULL_BRUSH));
        }
        break;
    case WM_PAINT: {
        PAINTSTRUCT ps {};
        const HDC hdc = BeginPaint(hwnd, &ps);
        if (host != nullptr && host->terminal.surface == nullptr) {
            HBRUSH brush = CreateSolidBrush(host->pane_background_color);
            FillRect(hdc, &ps.rcPaint, brush);
            DeleteObject(brush);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    default:
        break;
    }

    return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK browser_child_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* context = reinterpret_cast<PaneChildContext*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    auto* host = context != nullptr ? context->host : nullptr;

    switch (message) {
    case WM_NCCREATE: {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    case WM_LBUTTONDOWN:
        if (host != nullptr) set_active_pane(host, PaneKind::browser, L"mouse-click");
        return 0;
    case WM_KEYDOWN:
        if (host != nullptr && (wparam == VK_F6 || wparam == VK_TAB)) {
            cycle_focus(host, L"keyboard-cycle");
            return 0;
        }
        break;
    case WM_GETDLGCODE:
        return DLGC_WANTTAB | DLGC_WANTARROWS;
    case WM_PAINT: {
        PAINTSTRUCT ps {};
        const HDC hdc = BeginPaint(hwnd, &ps);
        if (host != nullptr) {
            HBRUSH brush = CreateSolidBrush(host->pane_background_color);
            FillRect(hdc, &ps.rcPaint, brush);
            DeleteObject(brush);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    default:
        break;
    }

    return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK splitter_child_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* context = reinterpret_cast<PaneChildContext*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    auto* host = context != nullptr ? context->host : nullptr;

    switch (message) {
    case WM_NCCREATE: {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    case WM_KEYDOWN:
        if (host != nullptr && (wparam == VK_F6 || wparam == VK_TAB)) {
            cycle_focus(host, L"keyboard-cycle");
            return 0;
        }
        break;
    case WM_GETDLGCODE:
        return DLGC_WANTTAB | DLGC_WANTARROWS;
    case WM_PAINT: {
        PAINTSTRUCT ps {};
        const HDC hdc = BeginPaint(hwnd, &ps);
        if (host != nullptr) {
            HBRUSH brush = CreateSolidBrush(host->splitter_color);
            FillRect(hdc, &ps.rcPaint, brush);
            DeleteObject(brush);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    default:
        break;
    }

    return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK shell_host_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* host = reinterpret_cast<ShellHostState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (message) {
    case WM_NCCREATE: {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    case WM_SIZE:
        if (host != nullptr) layout_children(host);
        return 0;
    case WM_SETFOCUS:
        if (host != nullptr) {
            host->saw_top_level_focus = true;
            append_line(host->action_log_path, L"shell:wm-setfocus");
            if (host->active_pane == PaneKind::terminal && host->terminal.hwnd != nullptr) {
                SetFocus(host->terminal.hwnd);
            } else if (host->active_pane == PaneKind::browser && host->browser.hwnd != nullptr) {
                SetFocus(host->browser.hwnd);
            }
        }
        return 0;
    case WM_TIMER:
        if (host != nullptr) {
            if (wparam == kGhosttyTickTimerId) {
                tick_ghostty(host);
                return 0;
            }
            if (wparam == kScenarioTimerId) {
                maybe_advance_scenario(host);
                return 0;
            }
            if (wparam == kFocusAuditTimerId) {
                KillTimer(hwnd, kFocusAuditTimerId);
                if (host->pending_focus_audit_pane != PaneKind::none) {
                    if (host->pending_focus_audit_pane == PaneKind::terminal &&
                        host->terminal.hwnd != nullptr) {
                        set_focus_with_browser_thread(host->hwnd, host->terminal.hwnd, host->browser.content_hwnd);
                    } else if (host->pending_focus_audit_pane == PaneKind::browser &&
                        host->browser.hwnd != nullptr) {
                        SetFocus(host->browser.hwnd);
                    }
                    append_focus_observation(
                        host,
                        host->pending_focus_audit_pane,
                        host->pending_focus_audit_reason.c_str(),
                        true
                    );
                    host->pending_focus_audit_pane = PaneKind::none;
                    host->pending_focus_audit_reason.clear();
                }
                return 0;
            }
            if (wparam == kTerminalReassertTimerId) {
                KillTimer(hwnd, kTerminalReassertTimerId);
                if (host->active_pane == PaneKind::terminal &&
                    host->terminal.hwnd != nullptr) {
                    set_focus_with_browser_thread(host->hwnd, host->terminal.hwnd, host->browser.content_hwnd);
                    append_focus_observation(host, PaneKind::terminal, L"terminal-reassert", true);
                }
                return 0;
            }
        }
        break;
    case kWakeupMessage:
        if (host != nullptr) {
            tick_ghostty(host);
            return 0;
        }
        break;
    case WM_DPICHANGED:
        if (host != nullptr) {
            host->last_dpi = HIWORD(wparam);
            host->dpi_change_count += 1;
            auto* suggested = reinterpret_cast<RECT*>(lparam);
            SetWindowPos(
                hwnd,
                nullptr,
                suggested->left,
                suggested->top,
                suggested->right - suggested->left,
                suggested->bottom - suggested->top,
                SWP_NOZORDER | SWP_NOACTIVATE
            );
            return 0;
        }
        break;
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
        if (host != nullptr) {
            update_high_contrast_state(host);
            invalidate_shell_visuals(host);
            trace_stage(host, L"accessibility-state-updated");
            return 0;
        }
        break;
    case WM_KEYDOWN:
        if (host != nullptr && (wparam == VK_F6 || wparam == VK_TAB)) {
            cycle_focus(host, L"keyboard-cycle");
            return 0;
        }
        break;
    case WM_PAINT: {
        PAINTSTRUCT ps {};
        const HDC hdc = BeginPaint(hwnd, &ps);
        if (host != nullptr) {
            HBRUSH brush = CreateSolidBrush(host->shell_background_color);
            FillRect(hdc, &ps.rcPaint, brush);
            DeleteObject(brush);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_CLOSE:
        if (host != nullptr) {
            host->should_quit = true;
            host->close_requested = true;
            trace_stage(host, L"wm-close-requested");
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }

    return DefWindowProcW(hwnd, message, wparam, lparam);
}

bool register_window_classes(HINSTANCE instance) {
    WNDCLASSW shell_class {};
    shell_class.lpfnWndProc = shell_host_proc;
    shell_class.hInstance = instance;
    shell_class.lpszClassName = L"CmuxShellHostSpikeWindow";
    shell_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);

    WNDCLASSW terminal_class {};
    terminal_class.lpfnWndProc = terminal_child_proc;
    terminal_class.hInstance = instance;
    terminal_class.lpszClassName = L"CmuxShellHostSpikeTerminal";
    terminal_class.hCursor = LoadCursorW(nullptr, IDC_IBEAM);

    WNDCLASSW browser_class {};
    browser_class.lpfnWndProc = browser_child_proc;
    browser_class.hInstance = instance;
    browser_class.lpszClassName = L"CmuxShellHostSpikeBrowser";
    browser_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);

    WNDCLASSW splitter_class {};
    splitter_class.lpfnWndProc = splitter_child_proc;
    splitter_class.hInstance = instance;
    splitter_class.lpszClassName = L"CmuxShellHostSpikeSplitter";
    splitter_class.hCursor = LoadCursorW(nullptr, IDC_SIZEWE);

    return (RegisterClassW(&shell_class) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS) &&
        (RegisterClassW(&terminal_class) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS) &&
        (RegisterClassW(&browser_class) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS) &&
        (RegisterClassW(&splitter_class) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS);
}

bool create_windows(HINSTANCE instance, ShellHostState* host) {
    host->hwnd = CreateWindowExW(
        WS_EX_CONTROLPARENT,
        L"CmuxShellHostSpikeWindow",
        kShellHostWindowName,
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1280,
        760,
        nullptr,
        nullptr,
        instance,
        host
    );
    if (host->hwnd == nullptr) return false;

    host->terminal_context = { host, PaneKind::terminal };
    host->browser_context = { host, PaneKind::browser };

    host->terminal.hwnd = CreateWindowExW(
        WS_EX_CONTROLPARENT,
        L"CmuxShellHostSpikeTerminal",
        kTerminalPaneBaseName,
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_GROUP,
        0,
        0,
        640,
        760,
        host->hwnd,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kTerminalPaneControlId)),
        instance,
        &host->terminal_context
    );
    if (host->terminal.hwnd == nullptr) return false;

    host->terminal.summary_hwnd = CreateWindowExW(
        0,
        L"STATIC",
        kTerminalSummaryBaseName,
        WS_CHILD | WS_VISIBLE,
        8,
        8,
        320,
        22,
        host->terminal.hwnd,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kTerminalSummaryControlId)),
        instance,
        nullptr
    );
    if (host->terminal.summary_hwnd == nullptr) return false;
    SendMessageW(
        host->terminal.summary_hwnd,
        WM_SETFONT,
        reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)),
        TRUE
    );

    host->splitter_hwnd = CreateWindowExW(
        WS_EX_TRANSPARENT,
        L"STATIC",
        kSplitterBaseName,
        WS_CHILD | WS_VISIBLE | SS_NOTIFY | SS_ETCHEDVERT,
        640,
        0,
        kSplitterWidth,
        760,
        host->hwnd,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kSplitterControlId)),
        instance,
        nullptr
    );
    if (host->splitter_hwnd == nullptr) return false;

    host->browser.hwnd = CreateWindowExW(
        WS_EX_CONTROLPARENT,
        L"CmuxShellHostSpikeBrowser",
        kBrowserPaneBaseName,
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_GROUP,
        640,
        0,
        640,
        760,
        host->hwnd,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kBrowserPaneControlId)),
        instance,
        &host->browser_context
    );
    if (host->browser.hwnd == nullptr) return false;
    layout_terminal_summary_child(host);
    refresh_accessibility_names(host);
    return true;
}

bool parse_arguments(ShellHostState& state, int argc, wchar_t** argv) {
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        auto require_value = [&](const wchar_t* name, std::wstring& output) -> bool {
            if (i + 1 >= argc) {
                fprintf(stderr, "missing value for %ls\n", name);
                return false;
            }
            output = argv[++i];
            return true;
        };

        if (arg == L"--report") {
            if (!require_value(L"--report", state.report_path)) return false;
        } else if (arg == L"--browser-url") {
            if (!require_value(L"--browser-url", state.requested_browser_url)) return false;
        } else if (arg == L"--browser-title") {
            if (!require_value(L"--browser-title", state.requested_browser_title)) return false;
        } else if (arg == L"--command") {
            if (!require_value(L"--command", state.requested_command)) return false;
        } else if (arg == L"--browser-helper") {
            if (!require_value(L"--browser-helper", state.requested_browser_helper)) return false;
        } else if (arg == L"--manual-focus") {
            state.manual_focus_mode = true;
        } else if (arg == L"--force-high-contrast") {
            state.force_high_contrast = true;
        } else if (arg == L"--hold-open-ms") {
            std::wstring hold_value;
            if (!require_value(L"--hold-open-ms", hold_value)) return false;
            state.hold_open_ms = static_cast<DWORD>(_wtoi(hold_value.c_str()));
        }
    }

    if (state.report_path.empty()) {
        fprintf(stderr, "missing --report\n");
        return false;
    }
    if (state.requested_browser_helper.empty()) {
        fprintf(stderr, "missing --browser-helper\n");
        return false;
    }
    if (state.requested_browser_url.empty()) {
        state.requested_browser_url = L"data:text/html,<html><head><title>DG3 Shell Host Spike</title></head><body>shell-host-browser</body></html>";
    }
    if (state.requested_browser_title.empty()) {
        state.requested_browser_title = L"DG3 Shell Host Spike";
    }
    if (state.requested_command.empty()) {
        state.requested_command = L"echo shell-host-spike && echo proof-line";
    }
    state.requested_command_utf8 = wide_to_narrow(state.requested_command);

    const auto report_dir = state.report_path.substr(0, state.report_path.find_last_of(L"\\/"));
    state.transcript_path = join_path(report_dir, L"shell-host-transcript.txt");
    state.focus_log_path = join_path(report_dir, L"shell-host-focus.log");
    state.action_log_path = join_path(report_dir, L"shell-host-actions.log");
    return true;
}

} // namespace

int main(int, char**) {
    HINSTANCE instance = GetModuleHandleW(nullptr);
    ShellHostState state {};
    state.start_tick = GetTickCount();

    wchar_t module_path[MAX_PATH] {};
    GetModuleFileNameW(nullptr, module_path, MAX_PATH);
    state.helper_path = module_path;

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv == nullptr) return 2;

    const bool parsed = parse_arguments(state, argc, argv);
    LocalFree(argv);
    if (!parsed) return 2;

    state.pmv2_enabled = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == TRUE;
    state.monitor_count = static_cast<UINT>(GetSystemMetrics(SM_CMONITORS));
    update_high_contrast_state(&state);

    std::ofstream(wide_to_narrow(state.focus_log_path), std::ios::binary | std::ios::trunc).close();
    std::ofstream(wide_to_narrow(state.action_log_path), std::ios::binary | std::ios::trunc).close();
    trace_stage(&state, L"main-start");

    const std::wstring ghostty_library_w = narrow_to_wide(std::getenv("CMUX_GHOSTTY_LIB") ? std::getenv("CMUX_GHOSTTY_LIB") : "libghostty.so");
    if (!load_ghostty_api(wide_to_narrow(ghostty_library_w).c_str())) return 3;
    trace_stage(&state, L"ghostty-api-loaded");

    char init_arg0[] = "cmux-shell-host-spike";
    char* init_argv[] = { init_arg0, nullptr };
    if (g_api.ghostty_init(1, init_argv) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "ghostty_init failed\n");
        return 4;
    }
    trace_stage(&state, L"ghostty-init-ready");

    int exit_code = 0;
    do {
        if (!register_window_classes(instance)) {
            fprintf(stderr, "register_window_classes failed\n");
            exit_code = 6;
            break;
        }
        trace_stage(&state, L"classes-ready");
        if (!create_windows(instance, &state)) {
            fprintf(stderr, "create_windows failed\n");
            exit_code = 7;
            break;
        }
        trace_stage(&state, L"windows-ready");

        state.initial_dpi = GetDpiForWindow(state.hwnd);
        state.last_dpi = state.initial_dpi;

        if (!initialize_terminal_gl(&state)) {
            fprintf(stderr, "initialize_terminal_gl failed\n");
            exit_code = 8;
            break;
        }
        if (!initialize_terminal_surface(&state)) {
            fprintf(stderr, "initialize_terminal_surface failed\n");
            exit_code = 9;
            break;
        }

        layout_children(&state);
        trace_stage(&state, L"layout-initial-ready");
        if (!initialize_browser_helper_host(&state)) {
            fprintf(stderr, "initialize_browser_helper_host failed\n");
            exit_code = 10;
            break;
        }

        SetTimer(state.hwnd, kGhosttyTickTimerId, kGhosttyTickMilliseconds, nullptr);
        SetTimer(state.hwnd, kScenarioTimerId, kScenarioTickMilliseconds, nullptr);
        trace_stage(&state, L"timers-ready");
        ShowWindow(state.hwnd, SW_SHOW);
        BringWindowToTop(state.hwnd);
        SetForegroundWindow(state.hwnd);
        SetActiveWindow(state.hwnd);
        trace_stage(&state, L"window-shown");

        DWORD deadline = GetTickCount() + kMaxRuntimeMilliseconds;
        while (!state.should_quit && GetTickCount() < deadline) {
            MSG message {};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
                if (message.message == WM_QUIT) {
                    state.should_quit = true;
                    break;
                }
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }

            tick_ghostty(&state);
            if (state.terminal.surface != nullptr &&
                state.terminal.child_exit_seen &&
                g_api.ghostty_surface_process_exited(state.terminal.surface) &&
                state.scenario_step >= 5) {
                Sleep(150);
                break;
            }

            Sleep(16);
        }

        if (!state.should_quit && GetTickCount() >= deadline) {
            append_line(state.focus_log_path, L"timeout=true");
        }
    } while (false);

    bool transcript_ok = false;
    std::wstring transcript_preview;
    if (state.terminal.surface != nullptr) {
        capture_terminal_transcript(&state, &transcript_ok, &transcript_preview);
        for (int attempt = 0; !transcript_ok && attempt < 12; ++attempt) {
            tick_ghostty(&state);
            Sleep(100);
            capture_terminal_transcript(&state, &transcript_ok, &transcript_preview);
        }
    }

    write_report(state, transcript_ok, transcript_preview);

    if (state.hwnd != nullptr) {
        trace_stage(&state, L"teardown-kill-timers");
        KillTimer(state.hwnd, kGhosttyTickTimerId);
        KillTimer(state.hwnd, kScenarioTimerId);
        KillTimer(state.hwnd, kFocusAuditTimerId);
        KillTimer(state.hwnd, kTerminalReassertTimerId);
        state.pending_focus_audit_pane = PaneKind::none;
        state.pending_focus_audit_reason.clear();
    }
    if (state.browser.content_hwnd != nullptr) {
        trace_stage(&state, L"teardown-browser-close");
        PostMessageW(state.browser.content_hwnd, WM_CLOSE, 0, 0);
    }
    if (state.browser.process != nullptr) {
        trace_stage(&state, L"teardown-browser-wait");
        WaitForSingleObject(state.browser.process, 2000);
        CloseHandle(state.browser.process);
        state.browser.process = nullptr;
    }
    if (state.terminal.surface != nullptr) {
        trace_stage(&state, L"teardown-terminal-unfocus");
        g_api.ghostty_surface_set_focus(state.terminal.surface, false);
        trace_stage(&state, L"teardown-terminal-surface-free");
        g_api.ghostty_surface_free(state.terminal.surface);
        state.terminal.surface = nullptr;
    }
    if (state.app != nullptr) {
        trace_stage(&state, L"teardown-app-free");
        g_api.ghostty_app_free(state.app);
        state.app = nullptr;
    }
    trace_stage(&state, L"teardown-gl-shutdown");
    shutdown_terminal_gl(&state);
    if (state.hwnd != nullptr) {
        trace_stage(&state, L"teardown-destroy-window");
        DestroyWindow(state.hwnd);
        state.hwnd = nullptr;
    }
    if (g_api.module != nullptr) {
        trace_stage(&state, L"teardown-free-library");
        FreeLibrary(g_api.module);
        g_api.module = nullptr;
    }

    const bool success =
        exit_code == 0 &&
        state.terminal.surface_created &&
        state.browser.controller_ready &&
        state.browser.navigation_completed &&
        state.focus_transfer_count >= 3 &&
        state.layout_pass_count >= 2 &&
        transcript_ok &&
        state.terminal.child_exit_seen &&
        state.terminal.child_exit_code == 0;

    return success ? 0 : (exit_code == 0 ? 10 : exit_code);
}
