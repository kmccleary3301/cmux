#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <shellapi.h>
#include <wrl.h>

#include <fstream>
#include <string>
#include <vector>

#include "WebView2.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

struct BrowserSpikeState {
    HWND hwnd = nullptr;
    std::wstring operation;
    std::wstring requested_url;
    std::wstring requested_title;
    std::wstring report_path;
    std::wstring helper_path;
    std::wstring final_url;
    std::wstring final_title;
    std::wstring status_message = L"starting";
    std::wstring failure_category;
    bool navigation_completed = false;
    bool title_seen = false;
    bool source_seen = false;
    bool controller_ready = false;
    bool success = false;
    bool finalized = false;
    int exit_code = 0;
    UINT_PTR timeout_timer = 0;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
};

constexpr wchar_t kWindowClassName[] = L"CmuxWindowsWebView2SpikeWindow";
constexpr UINT_PTR kTimeoutTimerId = 1;
constexpr UINT kTimeoutMilliseconds = 15000;

std::string narrow(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }

    int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) {
        return {};
    }

    std::string result(static_cast<size_t>(size - 1), '\0');
    WideCharToMultiByte(
        CP_UTF8,
        0,
        value.c_str(),
        -1,
        result.data(),
        size - 1,
        nullptr,
        nullptr
    );
    return result;
}

std::string json_escape(const std::wstring& value) {
    const std::string utf8 = narrow(value);
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

std::wstring join_path(const std::wstring& left, const std::wstring& right) {
    if (left.empty()) {
        return right;
    }
    if (left.back() == L'\\' || left.back() == L'/') {
        return left + right;
    }
    return left + L"\\" + right;
}

void write_report(const BrowserSpikeState& state) {
    std::ofstream out(narrow(state.report_path), std::ios::binary | std::ios::trunc);
    if (!out.is_open()) {
        return;
    }

    out
        << "{\n"
        << "  \"hostKind\": \"webview2\",\n"
        << "  \"operation\": \"" << json_escape(state.operation) << "\",\n"
        << "  \"requestedURL\": \"" << json_escape(state.requested_url) << "\",\n"
        << "  \"requestedTitle\": \"" << json_escape(state.requested_title) << "\",\n"
        << "  \"finalURL\": \"" << json_escape(state.final_url) << "\",\n"
        << "  \"finalTitle\": \"" << json_escape(state.final_title) << "\",\n"
        << "  \"statusMessage\": \"" << json_escape(state.status_message) << "\",\n"
        << "  \"failureCategory\": ";

    if (state.failure_category.empty()) {
        out << "null";
    } else {
        out << "\"" << json_escape(state.failure_category) << "\"";
    }

    out
        << ",\n"
        << "  \"navigationCompleted\": " << (state.navigation_completed ? "true" : "false") << ",\n"
        << "  \"titleSeen\": " << (state.title_seen ? "true" : "false") << ",\n"
        << "  \"sourceSeen\": " << (state.source_seen ? "true" : "false") << ",\n"
        << "  \"controllerReady\": " << (state.controller_ready ? "true" : "false") << ",\n"
        << "  \"success\": " << (state.success ? "true" : "false") << ",\n"
        << "  \"exitCode\": " << state.exit_code << ",\n"
        << "  \"helperPath\": \"" << json_escape(state.helper_path) << "\"\n"
        << "}\n";
}

void finalize_and_close(BrowserSpikeState* state, const std::wstring& status_message, const std::wstring& failure_category, bool success, int exit_code) {
    if (state == nullptr || state->finalized) {
        return;
    }

    state->finalized = true;
    state->status_message = status_message;
    state->failure_category = failure_category;
    state->success = success;
    state->exit_code = exit_code;

    if (state->timeout_timer != 0 && state->hwnd != nullptr) {
        KillTimer(state->hwnd, state->timeout_timer);
        state->timeout_timer = 0;
    }

    write_report(*state);

    if (state->hwnd != nullptr) {
        DestroyWindow(state->hwnd);
    }
}

void update_title(BrowserSpikeState* state) {
    if (state == nullptr || state->webview == nullptr) {
        return;
    }

    LPWSTR title = nullptr;
    if (SUCCEEDED(state->webview->get_DocumentTitle(&title)) && title != nullptr) {
        state->final_title = title;
        state->title_seen = !state->final_title.empty();
        CoTaskMemFree(title);
    }
}

void update_source(BrowserSpikeState* state) {
    if (state == nullptr || state->webview == nullptr) {
        return;
    }

    LPWSTR source = nullptr;
    if (SUCCEEDED(state->webview->get_Source(&source)) && source != nullptr) {
        state->final_url = source;
        state->source_seen = !state->final_url.empty();
        CoTaskMemFree(source);
    }
}

LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM w_param, LPARAM l_param) {
    BrowserSpikeState* state = reinterpret_cast<BrowserSpikeState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (message) {
    case WM_NCCREATE: {
        auto* create_struct = reinterpret_cast<CREATESTRUCTW*>(l_param);
        auto* incoming_state = reinterpret_cast<BrowserSpikeState*>(create_struct->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(incoming_state));
        if (incoming_state != nullptr) {
            incoming_state->hwnd = hwnd;
        }
        return DefWindowProcW(hwnd, message, w_param, l_param);
    }
    case WM_SIZE:
        if (state != nullptr && state->controller != nullptr) {
            RECT bounds {};
            GetClientRect(hwnd, &bounds);
            state->controller->put_Bounds(bounds);
        }
        return 0;
    case WM_TIMER:
        if (w_param == kTimeoutTimerId) {
            finalize_and_close(
                state,
                L"WebView2 navigation timed out",
                L"browser_navigation_timeout",
                false,
                1
            );
            return 0;
        }
        break;
    case WM_DESTROY:
        PostQuitMessage(state != nullptr ? state->exit_code : 0);
        return 0;
    default:
        break;
    }

    return DefWindowProcW(hwnd, message, w_param, l_param);
}

bool parse_arguments(BrowserSpikeState& state, int argc, wchar_t** argv) {
    for (int index = 1; index < argc; ++index) {
        const std::wstring arg = argv[index];
        auto require_value = [&](const wchar_t* name, std::wstring& output) -> bool {
            if (index + 1 >= argc) {
                state.status_message = std::wstring(L"missing value for ") + name;
                state.failure_category = L"argument_error";
                return false;
            }
            output = argv[++index];
            return true;
        };

        if (arg == L"--operation") {
            if (!require_value(L"--operation", state.operation)) {
                return false;
            }
        } else if (arg == L"--url") {
            if (!require_value(L"--url", state.requested_url)) {
                return false;
            }
        } else if (arg == L"--title") {
            if (!require_value(L"--title", state.requested_title)) {
                return false;
            }
        } else if (arg == L"--report") {
            if (!require_value(L"--report", state.report_path)) {
                return false;
            }
        }
    }

    if (state.operation.empty()) {
        state.operation = L"open-panel";
    }
    if (state.requested_url.empty()) {
        state.requested_url = L"about:blank";
    }
    if (state.requested_title.empty()) {
        state.requested_title = L"Browser";
    }
    if (state.report_path.empty()) {
        state.status_message = L"missing report path";
        state.failure_category = L"argument_error";
        return false;
    }

    return true;
}

bool register_window_class(HINSTANCE instance) {
    WNDCLASSEXW window_class {};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = instance;
    window_class.lpszClassName = kWindowClassName;
    window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);

    const ATOM result = RegisterClassExW(&window_class);
    return result != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    BrowserSpikeState state {};

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv == nullptr) {
        return 2;
    }

    wchar_t module_path[MAX_PATH] {};
    GetModuleFileNameW(nullptr, module_path, MAX_PATH);
    state.helper_path = module_path;

    const bool parsed = parse_arguments(state, argc, argv);
    LocalFree(argv);
    if (!parsed) {
        write_report(state);
        return 2;
    }

    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(com_result)) {
        state.status_message = L"CoInitializeEx failed";
        state.failure_category = L"com_init_failure";
        state.exit_code = 3;
        write_report(state);
        return state.exit_code;
    }

    int exit_code = 0;

    do {
        if (!register_window_class(instance)) {
            state.status_message = L"RegisterClassExW failed";
            state.failure_category = L"window_class_failure";
            exit_code = 4;
            break;
        }

        HWND hwnd = CreateWindowExW(
            0,
            kWindowClassName,
            L"cmux WebView2 Spike",
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1024,
            720,
            nullptr,
            nullptr,
            instance,
            &state
        );
        if (hwnd == nullptr) {
            state.status_message = L"CreateWindowExW failed";
            state.failure_category = L"window_create_failure";
            exit_code = 5;
            break;
        }

        state.timeout_timer = SetTimer(hwnd, kTimeoutTimerId, kTimeoutMilliseconds, nullptr);
        ShowWindow(hwnd, SW_HIDE);

        HRESULT environment_result = CreateCoreWebView2EnvironmentWithOptions(
            nullptr,
            nullptr,
            nullptr,
            Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                [&state](HRESULT result, ICoreWebView2Environment* environment) -> HRESULT {
                    if (FAILED(result) || environment == nullptr) {
                        finalize_and_close(
                            &state,
                            L"CreateCoreWebView2EnvironmentWithOptions failed",
                            L"browser_environment_failure",
                            false,
                            6
                        );
                        return S_OK;
                    }

                    environment->CreateCoreWebView2Controller(
                        state.hwnd,
                        Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [&state](HRESULT controller_result, ICoreWebView2Controller* controller) -> HRESULT {
                                if (FAILED(controller_result) || controller == nullptr) {
                                    finalize_and_close(
                                        &state,
                                        L"CreateCoreWebView2Controller failed",
                                        L"browser_controller_failure",
                                        false,
                                        7
                                    );
                                    return S_OK;
                                }

                                state.controller = controller;
                                state.controller_ready = true;
                                state.controller->get_CoreWebView2(&state.webview);

                                RECT bounds {};
                                GetClientRect(state.hwnd, &bounds);
                                state.controller->put_Bounds(bounds);

                                state.webview->add_DocumentTitleChanged(
                                    Callback<ICoreWebView2DocumentTitleChangedEventHandler>(
                                        [&state](ICoreWebView2*, IUnknown*) -> HRESULT {
                                            update_title(&state);
                                            return S_OK;
                                        }
                                    ).Get(),
                                    nullptr
                                );

                                state.webview->add_SourceChanged(
                                    Callback<ICoreWebView2SourceChangedEventHandler>(
                                        [&state](ICoreWebView2*, ICoreWebView2SourceChangedEventArgs*) -> HRESULT {
                                            update_source(&state);
                                            return S_OK;
                                        }
                                    ).Get(),
                                    nullptr
                                );

                                state.webview->add_NavigationCompleted(
                                    Callback<ICoreWebView2NavigationCompletedEventHandler>(
                                        [&state](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
                                            BOOL is_success = FALSE;
                                            if (args != nullptr) {
                                                args->get_IsSuccess(&is_success);
                                            }

                                            update_title(&state);
                                            update_source(&state);
                                            state.navigation_completed = is_success == TRUE;

                                            if (state.navigation_completed) {
                                                if (!state.source_seen) {
                                                    state.final_url = state.requested_url;
                                                    state.source_seen = !state.final_url.empty();
                                                }
                                                if (!state.title_seen) {
                                                    state.final_title = state.requested_title;
                                                    state.title_seen = true;
                                                }
                                                finalize_and_close(
                                                    &state,
                                                    L"WebView2 navigation completed",
                                                    L"",
                                                    true,
                                                    0
                                                );
                                            } else {
                                                finalize_and_close(
                                                    &state,
                                                    L"WebView2 navigation failed",
                                                    L"browser_navigation_failure",
                                                    false,
                                                    8
                                                );
                                            }
                                            return S_OK;
                                        }
                                    ).Get(),
                                    nullptr
                                );

                                state.webview->Navigate(state.requested_url.c_str());
                                return S_OK;
                            }
                        ).Get()
                    );
                    return S_OK;
                }
            ).Get()
        );

        if (FAILED(environment_result)) {
            state.status_message = L"CreateCoreWebView2EnvironmentWithOptions entrypoint failed";
            state.failure_category = L"browser_environment_entry_failure";
            exit_code = 9;
            break;
        }

        MSG message {};
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        exit_code = static_cast<int>(message.wParam);
    } while (false);

    if (!state.finalized) {
        if (state.failure_category.empty()) {
            state.failure_category = L"browser_helper_unexpected_exit";
        }
        if (state.status_message.empty()) {
            state.status_message = L"browser helper exited unexpectedly";
        }
        state.exit_code = exit_code;
        write_report(state);
    }

    CoUninitialize();
    return exit_code;
}
