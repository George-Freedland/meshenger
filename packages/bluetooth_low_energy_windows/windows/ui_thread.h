#ifndef FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_UI_THREAD_H_
#define FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_UI_THREAD_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objbase.h>

#include <atomic>
#include <deque>
#include <functional>
#include <iostream>
#include <mutex>

#include "winrt/Windows.Foundation.h"

namespace bluetooth_low_energy_windows
{
	// A dropped callback is an event (an advertisement heard, a peer's
	// write) the app never sees. Report the first few, then every 500th.
	inline void ReportDroppedCallback(const char *reason)
	{
		static std::atomic<int> dropped{0};
		const auto count = ++dropped;
		if (count <= 5 || count % 500 == 0)
		{
			std::cerr << "[bluetooth_low_energy_windows] dropped a Bluetooth event (" << count
					  << " so far): " << reason << std::endl;
		}
	}

	// Platform channel messages must be sent from the Flutter platform
	// thread, but WinRT event handlers and coroutine continuations run on
	// the thread pool. Work for the platform thread queues here and a
	// window message wakes it up.
	//
	// This used to go through the thread's COM apartment, which has two
	// problems: another component on that thread (Dart code runs there too)
	// can shut COM down, and from then on every Bluetooth event was dropped
	// until the app restarted; and marshaling into an apartment blocks the
	// caller until the platform thread gets to it, so a burst of
	// notifications waited on the UI one at a time. A window message needs
	// neither COM nor a waiting caller.
	namespace platform_thread
	{
		inline constexpr UINT kRunMessage = WM_APP + 0x0B1E; // inside WM_APP's 0x8000-0xBFFF
		inline std::mutex queue_mutex;
		inline std::deque<std::function<void()>> pending;
		inline bool wake_posted = false;
		inline HWND wake_window = nullptr;
		inline DWORD thread_id = 0;

		inline bool IsCurrent()
		{
			return thread_id != 0 && GetCurrentThreadId() == thread_id;
		}

		// WinRT calls on the platform thread need COM. When another
		// component has shut it down there, start it again (and say so).
		inline void EnsureCom()
		{
			if (!IsCurrent())
			{
				return;
			}
			const auto hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
			if (hr == S_FALSE)
			{
				CoUninitialize(); // already running: undo our extra reference
			}
			else if (hr == S_OK)
			{
				std::cerr << "[bluetooth_low_energy_windows] COM on the app's main thread had been shut down "
							 "by another component; started it again"
						  << std::endl;
			}
			// RPC_E_CHANGED_MODE: someone made it multithreaded; WinRT works there too.
		}

		inline void Drain()
		{
			EnsureCom();
			std::deque<std::function<void()>> work;
			{
				std::lock_guard<std::mutex> lock(queue_mutex);
				work.swap(pending);
				wake_posted = false;
			}
			for (auto &item : work)
			{
				try
				{
					item();
				}
				catch (const winrt::hresult_error &ex)
				{
					ReportDroppedCallback(winrt::to_string(ex.message()).c_str());
				}
				catch (const std::exception &ex)
				{
					ReportDroppedCallback(ex.what());
				}
				catch (...)
				{
					ReportDroppedCallback("unknown error");
				}
			}
		}

		inline LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
		{
			if (message == kRunMessage)
			{
				Drain();
				return 0;
			}
			return DefWindowProcW(hwnd, message, wparam, lparam);
		}

		// Call once, on the platform thread, before anything is posted.
		inline void Initialize()
		{
			if (wake_window != nullptr)
			{
				return;
			}
			thread_id = GetCurrentThreadId();
			WNDCLASSEXW window_class = {};
			window_class.cbSize = sizeof(window_class);
			window_class.lpfnWndProc = WindowProc;
			window_class.hInstance = GetModuleHandleW(nullptr);
			window_class.lpszClassName = L"BluetoothLowEnergyWindowsPlatformThread";
			RegisterClassExW(&window_class);
			wake_window = CreateWindowExW(0, window_class.lpszClassName, L"", 0, 0, 0, 0, 0,
										  HWND_MESSAGE, nullptr, window_class.hInstance, nullptr);
		}

		// Never blocks; [work] runs on the platform thread, in posting order.
		inline void Post(std::function<void()> work)
		{
			auto wake = false;
			HWND target = nullptr;
			{
				std::lock_guard<std::mutex> lock(queue_mutex);
				pending.push_back(std::move(work));
				if (!wake_posted)
				{
					wake_posted = true;
					wake = true;
				}
				target = wake_window;
			}
			if (wake && (target == nullptr || !PostMessageW(target, kRunMessage, 0, 0)))
			{
				std::lock_guard<std::mutex> lock(queue_mutex);
				wake_posted = false;
				ReportDroppedCallback("the app's main thread isn't taking messages");
			}
		}
	}

	// Runs [fn] on the platform thread: right away when already there,
	// otherwise queued. [context] is kept for the call sites; the queue
	// doesn't need it.
	inline void RunOnApartment(winrt::apartment_context /*context*/, std::function<void()> fn)
	{
		if (platform_thread::IsCurrent())
		{
			try
			{
				fn();
			}
			catch (const winrt::hresult_error &ex)
			{
				ReportDroppedCallback(winrt::to_string(ex.message()).c_str());
			}
			catch (const std::exception &ex)
			{
				ReportDroppedCallback(ex.what());
			}
			return;
		}
		platform_thread::Post(std::move(fn));
	}

	// co_await this to continue on the platform thread. Unlike awaiting an
	// apartment_context, it can't throw when that apartment has gone.
	struct ResumeOnPlatformThread
	{
		bool await_ready() const noexcept
		{
			return platform_thread::IsCurrent();
		}

		template <typename Handle>
		void await_suspend(Handle handle) const
		{
			platform_thread::Post([handle]() mutable { handle.resume(); });
		}

		void await_resume() const noexcept {}
	};

	// Wraps a pigeon reply callback so it is always invoked on the platform
	// thread, no matter which thread the coroutine finished on. Made on the
	// platform thread as each call comes in from Dart, so it also checks
	// COM there first.
	template <typename T>
	inline std::function<void(T)> WrapReply(winrt::apartment_context context, std::function<void(T)> reply)
	{
		platform_thread::EnsureCom();
		return [context, reply = std::move(reply)](T value)
		{
			RunOnApartment(context, [reply, value = std::move(value)]() { reply(value); });
		};
	}
}

#endif // !FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_UI_THREAD_H_
