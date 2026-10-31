#ifndef FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_UI_THREAD_H_
#define FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_UI_THREAD_H_

#include <atomic>
#include <functional>
#include <iostream>

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
	// thread, but WinRT coroutines and event handlers resume on the thread
	// pool. This helper marshals [fn] back onto the apartment captured in
	// [context] (captured on the platform thread at manager construction).
	inline winrt::fire_and_forget RunOnApartment(winrt::apartment_context context, std::function<void()> fn)
	{
		try
		{
			co_await context;
			fn();
		}
		catch (const winrt::hresult_error &ex)
		{
			// Usually the apartment is gone (app shutting down).
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

	// Wraps a pigeon reply callback so it is always invoked on the platform
	// thread, no matter which thread the coroutine finished on.
	template <typename T>
	inline std::function<void(T)> WrapReply(winrt::apartment_context context, std::function<void(T)> reply)
	{
		return [context, reply = std::move(reply)](T value)
		{
			RunOnApartment(context, [reply, value = std::move(value)]() { reply(value); });
		};
	}
}

#endif // !FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_UI_THREAD_H_
