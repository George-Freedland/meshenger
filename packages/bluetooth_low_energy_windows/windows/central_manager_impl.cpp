#undef _HAS_EXCEPTIONS

#include "central_manager_impl.h"

namespace bluetooth_low_energy_windows
{
	CentralManagerImpl::CentralManagerImpl(flutter::BinaryMessenger *messenger)
	{
		const auto api = CentralManagerFlutterApi(messenger);
		const auto watcher = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher();
		watcher.ScanningMode(winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEScanningMode::Active);
		m_api = api;
		m_watcher = watcher;
	}

	CentralManagerImpl::~CentralManagerImpl()
	{
	}

	void CentralManagerImpl::Initialize(std::function<void(std::optional<FlutterError> reply)> result)
	{
		InitializeAsync(WrapReply(m_ui_context, std::move(result)));
	}

	ErrorOr<BluetoothLowEnergyStateArgs> CentralManagerImpl::GetState()
	{
		try
		{
			const auto has_adapter = m_adapter.has_value();
			if (has_adapter)
			{
				const auto &adapter = m_adapter.value();
				const auto supported = adapter.IsCentralRoleSupported();
				if (supported)
				{
					const auto &radio = m_radio.value();
					const auto state = radio.State();
					const auto state_args = RadioStateToArgs(state);
					return state_args;
				}
			}
			return BluetoothLowEnergyStateArgs::kUnsupported;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	std::optional<FlutterError> CentralManagerImpl::StartDiscovery(const flutter::EncodableList &service_uuids_args)
	{
		try
		{
			const auto &watcher = m_watcher.value();
			const auto filter = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementFilter::BluetoothLEAdvertisementFilter();
			const auto advertisement = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisement();
			const auto service_uuids = advertisement.ServiceUuids();
			for (const auto &service_uuid_args_value : service_uuids_args)
			{
				const auto &service_uuid_args = std::get<std::string>(service_uuid_args_value);
				const auto service_uuid = winrt::guid(service_uuid_args);
				service_uuids.Append(service_uuid);
			}
			filter.Advertisement(advertisement);
			watcher.AdvertisementFilter(filter);
			m_discovering = true;
			watcher.Start();
			return std::nullopt;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	std::optional<FlutterError> CentralManagerImpl::StopDiscovery()
	{
		try
		{
			const auto &watcher = m_watcher.value();
			m_discovering = false;
			watcher.Stop();
			return std::nullopt;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	void CentralManagerImpl::Connect(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		ConnectAsync(address_args, WrapReply(m_ui_context, std::move(result)));
	}

	std::optional<FlutterError> CentralManagerImpl::Disconnect(int64_t address_args)
	{
		try
		{
			CloseConnection(address_args);
			OnDisconnected(address_args);
			auto &api = m_api.value();
			const auto peripheral_args = PeripheralArgs(address_args);
			const auto state_args = ConnectionStateArgs::kDisconnected;
			// TODO: Make this thread safe when this issue closed: https://github.com/flutter/flutter/issues/134346.
			api.OnConnectionStateChanged(peripheral_args, state_args, [] {}, [](auto error) {});
			return std::nullopt;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	ErrorOr<int64_t> CentralManagerImpl::GetMTU(int64_t address_args)
	{
		try
		{
			const auto &session = m_sessions[address_args].value();
			const auto mtu = session.MaxPduSize();
			const auto mtu_args = static_cast<int64_t>(mtu);
			return mtu_args;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	void CentralManagerImpl::GetServices(int64_t address_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetServicesAsync(address_args, mode_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::GetIncludedServices(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetIncludedServicesAsync(address_args, handle_args, mode_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::GetCharacteristics(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetCharacteristicsAsync(address_args, handle_args, mode_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::GetDescriptors(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetDescriptorsAsync(address_args, handle_args, mode_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::ReadCharacteristic(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		ReadCharacteristicAsync(address_args, handle_args, mode_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::WriteCharacteristic(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, const GATTCharacteristicWriteTypeArgs &type_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		WriteCharacteristicAsync(address_args, handle_args, value_args, type_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::SetCharacteristicNotifyState(int64_t address_args, int64_t handle_args, const GATTCharacteristicNotifyStateArgs &state_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		SetCharacteristicNotifyStateAsync(address_args, handle_args, state_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::ReadDescriptor(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		ReadDescriptorAsync(address_args, handle_args, mode_args, WrapReply(m_ui_context, std::move(result)));
	}

	void CentralManagerImpl::WriteDescriptor(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		WriteDescriptorAsync(address_args, handle_args, value_args, WrapReply(m_ui_context, std::move(result)));
	}

	winrt::fire_and_forget CentralManagerImpl::InitializeAsync(std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &watcher = m_watcher.value();
			const auto status = watcher.Status();
			m_discovering = false;
			if (status == winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcherStatus::Started)
			{
				watcher.Stop();
			}

			for (const auto &item : m_devices)
			{
				const auto address_args = item.first;
				OnDisconnected(address_args);
			}

			const auto &adapter = co_await winrt::Windows::Devices::Bluetooth::BluetoothAdapter::GetDefaultAsync();
			if (adapter != NULL)
			{
				const auto supported = adapter.IsCentralRoleSupported();
				if (supported)
				{
					const auto &radio = co_await adapter.GetRadioAsync();
					m_radio_state_changed_revoker = radio.StateChanged(
						winrt::auto_revoke,
						[this](winrt::Windows::Devices::Radios::Radio radio, auto obj)
						{
							const auto state = radio.State();
							const auto state_args = RadioStateToArgs(state);
							RunOnApartment(m_ui_context, [this, state_args]
							{
								auto &api = m_api.value();
								api.OnStateChanged(state_args, [] {}, [](auto error) {});
							});
						});
					m_radio = radio;
				}
				else
				{
					m_radio.reset();
				}
				m_adapter = adapter;
			}
			else
			{
				m_adapter.reset();
			}

			m_watcher_received_revoker = watcher.Received(
				winrt::auto_revoke,
				[this](winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher watcher, winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementReceivedEventArgs event_args)
				{
					if (++m_adverts_received == 1)
					{
						std::cerr << "[bluetooth_low_energy_windows] scan: Windows delivered its first advertisement" << std::endl;
					}
					try
					{
						const auto address = event_args.BluetoothAddress();
						const auto address_args = static_cast<int64_t>(address);
						// Remember the address type so ConnectAsync can resolve
						// peripherals that use random addressing (macOS/iOS).
						const auto address_type = event_args.BluetoothAddressType();
						const auto peripheral_args = PeripheralArgs(address_args);
						const auto rssi = event_args.RawSignalStrengthInDBm();
						const auto rssi_args = static_cast<int64_t>(rssi);
						const auto &file_timestamp = event_args.Timestamp();
						const auto timestamp = std::chrono::clock_cast<std::chrono::system_clock>(file_timestamp).time_since_epoch();
						const auto timestamp_args = std::chrono::duration_cast<std::chrono::milliseconds>(timestamp).count();
						const auto type = event_args.AdvertisementType();
						const auto type_args = AdvertisementTypeToArgs(type);
						const auto advertisement = event_args.Advertisement();
						const auto advertisement_args = AdvertisementToArgs(advertisement);
						RunOnApartment(m_ui_context, [this, address_args, address_type, peripheral_args, rssi_args, timestamp_args, type_args, advertisement_args]
						{
							m_address_types[address_args] = address_type;
							auto &api = m_api.value();
							api.OnDiscovered(peripheral_args, rssi_args, timestamp_args, type_args, advertisement_args, [] {}, [](const FlutterError &error)
							{
								ReportDroppedCallback(("the app rejected an advertisement: " + error.code() + " " + error.message()).c_str());
							});
							if (!m_reported_first_delivery.exchange(true))
							{
								std::cerr << "[bluetooth_low_energy_windows] scan: first advertisement passed to the app" << std::endl;
							}
						});
					}
					catch (const winrt::hresult_error &ex)
					{
						ReportDroppedCallback(("reading an advertisement: " + winrt::to_string(ex.message())).c_str());
					}
					catch (const std::exception &ex)
					{
						ReportDroppedCallback((std::string("reading an advertisement: ") + ex.what()).c_str());
					}
				});
			m_watcher_stopped_revoker = watcher.Stopped(
				winrt::auto_revoke,
				[this](winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher watcher, winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcherStoppedEventArgs event_args)
				{
					if (!m_discovering)
					{
						return; // the app stopped it
					}
					std::cerr << "[bluetooth_low_energy_windows] Windows stopped the scan (BluetoothError "
							  << static_cast<int32_t>(event_args.Error()) << ") - restarting it" << std::endl;
					RestartDiscoveryAsync(std::chrono::seconds(2));
				});
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::RestartDiscoveryAsync(winrt::Windows::Foundation::TimeSpan delay)
	{
		co_await winrt::resume_after(delay);
		co_await m_ui_context;
		if (!m_discovering)
		{
			co_return;
		}
		auto retry = false;
		try
		{
			const auto &watcher = m_watcher.value();
			const auto status = watcher.Status();
			if (status == winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcherStatus::Started)
			{
				co_return;
			}
			if (status == winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcherStatus::Stopping)
			{
				retry = true; // can't start until it has fully stopped
			}
			else
			{
				watcher.Start();
				std::cerr << "[bluetooth_low_energy_windows] scan restarted" << std::endl;
			}
		}
		catch (const winrt::hresult_error &ex)
		{
			std::cerr << "[bluetooth_low_energy_windows] scan restart failed: "
					  << winrt::to_string(ex.message()) << std::endl;
			retry = true;
		}
		if (retry)
		{
			RestartDiscoveryAsync(std::chrono::seconds(10));
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ConnectAsync(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto address = static_cast<uint64_t>(address_args);
			// FromBluetoothAddressAsync(address) assumes a public address and
			// returns null for peripherals using random addressing (macOS/iOS).
			// Use the address type captured during discovery when available.
			auto device = winrt::Windows::Devices::Bluetooth::BluetoothLEDevice(nullptr);
			const auto type_iterator = m_address_types.find(address_args);
			if (type_iterator != m_address_types.end() &&
				type_iterator->second != winrt::Windows::Devices::Bluetooth::BluetoothAddressType::Unspecified)
			{
				device = co_await winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::FromBluetoothAddressAsync(address, type_iterator->second);
			}
			if (device == nullptr)
			{
				device = co_await winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::FromBluetoothAddressAsync(address);
			}
			if (device == nullptr)
			{
				throw BluetoothLowEnergyException("Connect failed: device not found (it may have stopped advertising or rotated its address)");
			}
			const auto id = device.BluetoothDeviceId();
			const auto &session = co_await winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession::FromDeviceIdAsync(id);
			// Creating a BluetoothLEDevice object by calling this method alone doesn't (necessarily) initiate a
			// connection. To initiate a connection, set GattSession.MaintainConnection to true, or call an
			// uncached service discovery method on BluetoothLEDevice, or perform a read/write operation against
			// the device.
			// See：https://learn.microsoft.com/en-us/windows/uwp/devices-sensors/gatt-client#connecting-to-the-device
			const auto &r = co_await device.GetGattServicesAsync(winrt::Windows::Devices::Bluetooth::BluetoothCacheMode::Uncached);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Connect failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto peripheral_args = PeripheralArgs(address_args);
			const auto state_args = ConnectionStateArgs::kConnected;
			const auto mtu = session.MaxPduSize();
			const auto mtu_args = static_cast<int64_t>(mtu);
			RunOnApartment(m_ui_context, [this, address_args, peripheral_args, state_args, mtu_args, device, session]
			{
				auto &api = m_api.value();
				api.OnConnectionStateChanged(peripheral_args, state_args, [] {}, [](auto error) {});
				api.OnMTUChanged(peripheral_args, mtu_args, [] {}, [](auto error) {});
				m_device_connection_status_changed_revokers[address_args] = device.ConnectionStatusChanged(
					winrt::auto_revoke,
					[this, address_args](winrt::Windows::Devices::Bluetooth::BluetoothLEDevice device, auto obj)
					{
						const auto status = device.ConnectionStatus();
						RunOnApartment(m_ui_context, [this, address_args, status]
						{
							if (status == winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus::Disconnected)
							{
								OnDisconnected(address_args);
							}
							auto &api = m_api.value();
							const auto peripheral_args = PeripheralArgs(address_args);
							const auto state_args = ConnectionStatusToArgs(status);
							api.OnConnectionStateChanged(peripheral_args, state_args, [] {}, [](auto error) {});
						});
					});
				m_session_max_pdu_size_changed_revokers[address_args] = session.MaxPduSizeChanged(
					winrt::auto_revoke,
					[this, peripheral_args](winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession session, auto obj)
					{
						const auto mtu = session.MaxPduSize();
						const auto mtu_args = static_cast<int64_t>(mtu);
						RunOnApartment(m_ui_context, [this, peripheral_args, mtu_args]
						{
							auto &api = m_api.value();
							api.OnMTUChanged(peripheral_args, mtu_args, [] {}, [](auto error) {});
						});
					});
				m_devices[address_args] = device;
				m_sessions[address_args] = session;
			});
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetServicesAsync(int64_t address_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &device = RetrieveDevice(address_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await device.GetGattServicesAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get services failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto services = r.Services();
			auto services_args = flutter::EncodableList();
			for (const auto service : services)
			{
				const auto service_args = ServiceToArgs(service);
				const auto service_args_value = flutter::CustomEncodableValue(service_args);
				const auto service_handle_args = service_args.handle_args();
				m_services[address_args][service_handle_args] = service;
				services_args.emplace_back(service_args_value);
			}
			result(services_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetIncludedServicesAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &service = RetrieveService(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await service.GetIncludedServicesAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get included services failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto included_services = r.Services();
			auto included_services_args = flutter::EncodableList();
			for (const auto included_service : included_services)
			{
				const auto service_args = ServiceToArgs(included_service);
				const auto service_args_value = flutter::CustomEncodableValue(service_args);
				const auto service_handle_args = service_args.handle_args();
				m_services[address_args][service_handle_args] = included_service;
				included_services_args.emplace_back(service_args_value);
			}
			result(included_services_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetCharacteristicsAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &service = RetrieveService(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await service.GetCharacteristicsAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get characteristics failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto characteristics = r.Characteristics();
			auto characteristics_args = flutter::EncodableList();
			for (const auto characteristic : characteristics)
			{
				const auto characteristic_args = CharacteristicToArgs(characteristic);
				const auto characteristic_args_value = flutter::CustomEncodableValue(characteristic_args);
				const auto characteristic_handle_args = characteristic_args.handle_args();
				m_characteristic_value_changed_revokers[address_args][characteristic_handle_args] = characteristic.ValueChanged(
					winrt::auto_revoke,
					[this, address_args](const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &characteristic, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattValueChangedEventArgs &event_args)
					{
						const auto peripheral_args = PeripheralArgs(address_args);
						const auto characteristic_args = CharacteristicToArgs(characteristic);
						const auto value = event_args.CharacteristicValue();
						const auto value_length = value.Length();
						auto value_args = std::vector<uint8_t>(value_length);
						const auto value_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(value);
						value_reader.ReadBytes(value_args);
						RunOnApartment(m_ui_context, [this, peripheral_args, characteristic_args, value_args]
						{
							auto &api = m_api.value();
							api.OnCharacteristicNotified(peripheral_args, characteristic_args, value_args, []() {}, [](const auto &error) {});
						});
					});
				m_characteristics[address_args][characteristic_handle_args] = characteristic;
				characteristics_args.emplace_back(characteristic_args_value);
			}
			result(characteristics_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetDescriptorsAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await characteristic.GetDescriptorsAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get descriptors failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto descriptors = r.Descriptors();
			auto descriptors_args = flutter::EncodableList();
			for (const auto descriptor : descriptors)
			{
				const auto descriptor_args = DescriptorToArgs(descriptor);
				const auto descriptor_args_value = flutter::CustomEncodableValue(descriptor_args);
				const auto descriptor_handle_args = descriptor_args.handle_args();
				m_descriptors[address_args][descriptor_handle_args] = descriptor;
				descriptors_args.emplace_back(descriptor_args_value);
			}
			result(descriptors_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ReadCharacteristicAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await characteristic.ReadValueAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Read characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto value = r.Value();
			const auto value_length = value.Length();
			auto value_args = std::vector<uint8_t>(value_length);
			const auto value_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(value);
			value_reader.ReadBytes(value_args);
			result(value_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::WriteCharacteristicAsync(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, const GATTCharacteristicWriteTypeArgs &type_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto value_writer = winrt::Windows::Storage::Streams::DataWriter();
			value_writer.WriteBytes(value_args);
			const auto value = value_writer.DetachBuffer();
			const auto option = ArgsToWriteOption(type_args);
			const auto status = co_await characteristic.WriteValueAsync(value, option);
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Write characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::SetCharacteristicNotifyStateAsync(int64_t address_args, int64_t handle_args, const GATTCharacteristicNotifyStateArgs &state_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto value = ArgsToCCCDescriptorValue(state_args);
			const auto status = co_await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(value);
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Notify characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ReadDescriptorAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		try
		{
			const auto &descriptor = RetrieveDescriptor(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await descriptor.ReadValueAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Read descriptor failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto value = r.Value();
			const auto value_length = value.Length();
			auto value_args = std::vector<uint8_t>(value_length);
			const auto value_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(value);
			value_reader.ReadBytes(value_args);
			result(value_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::WriteDescriptorAsync(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &descriptor = RetrieveDescriptor(address_args, handle_args);
			const auto value_writer = winrt::Windows::Storage::Streams::DataWriter();
			value_writer.WriteBytes(value_args);
			const auto value = value_writer.DetachBuffer();
			const auto status = co_await descriptor.WriteValueAsync(value);
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Write characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	// Dropping our references alone leaves the link up until Windows releases
	// the GATT session on its own, which keeps the peer connected and gets in
	// the way of the next connection to it. Close everything explicitly.
	void CentralManagerImpl::CloseConnection(int64_t address_args)
	{
		const auto services_iterator = m_services.find(address_args);
		if (services_iterator != m_services.end())
		{
			for (auto &service_entry : services_iterator->second)
			{
				if (service_entry.second.has_value())
				{
					try
					{
						service_entry.second->Close();
					}
					catch (const winrt::hresult_error &)
					{
					}
				}
			}
		}
		const auto session_iterator = m_sessions.find(address_args);
		if (session_iterator != m_sessions.end() && session_iterator->second.has_value())
		{
			try
			{
				session_iterator->second->Close();
			}
			catch (const winrt::hresult_error &)
			{
			}
		}
		const auto device_iterator = m_devices.find(address_args);
		if (device_iterator != m_devices.end() && device_iterator->second.has_value())
		{
			try
			{
				device_iterator->second->Close();
			}
			catch (const winrt::hresult_error &)
			{
			}
		}
	}

	void CentralManagerImpl::OnDisconnected(int64_t address_args)
	{
		m_device_connection_status_changed_revokers.erase(address_args);
		m_session_max_pdu_size_changed_revokers.erase(address_args);
		m_characteristic_value_changed_revokers.erase(address_args);
		m_devices.erase(address_args);
		m_sessions.erase(address_args);
		m_services.erase(address_args);
		m_characteristics.erase(address_args);
		m_descriptors.erase(address_args);
	}

	winrt::Windows::Devices::Bluetooth::BluetoothLEDevice &CentralManagerImpl::RetrieveDevice(int64_t address_args)
	{
		return m_devices[address_args].value();
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService &CentralManagerImpl::RetrieveService(int64_t address_args, int64_t handle_args)
	{
		return m_services[address_args][handle_args].value();
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &CentralManagerImpl::RetrieveCharacteristic(int64_t address_args, int64_t handle_args)
	{
		return m_characteristics[address_args][handle_args].value();
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDescriptor &CentralManagerImpl::RetrieveDescriptor(int64_t address_args, int64_t handle_args)
	{
		return m_descriptors[address_args][handle_args].value();
	}

	BluetoothLowEnergyStateArgs CentralManagerImpl::RadioStateToArgs(const winrt::Windows::Devices::Radios::RadioState &state)
	{
		switch (state)
		{
		case winrt::Windows::Devices::Radios::RadioState::Unknown:
			return BluetoothLowEnergyStateArgs::kUnknown;
		case winrt::Windows::Devices::Radios::RadioState::Disabled:
			return BluetoothLowEnergyStateArgs::kDisabled;
		case winrt::Windows::Devices::Radios::RadioState::Off:
			return BluetoothLowEnergyStateArgs::kOff;
		case winrt::Windows::Devices::Radios::RadioState::On:
			return BluetoothLowEnergyStateArgs::kOn;
		default:
			return BluetoothLowEnergyStateArgs::kUnknown;
		}
	}

	AdvertisementTypeArgs CentralManagerImpl::AdvertisementTypeToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType &type)
	{
		switch (type)
		{
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ConnectableUndirected:
			return AdvertisementTypeArgs::kConnectableUndirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ConnectableDirected:
			return AdvertisementTypeArgs::kConnectableDirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ScannableUndirected:
			return AdvertisementTypeArgs::kScannableUndirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::NonConnectableUndirected:
			return AdvertisementTypeArgs::kNonConnectableUndirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ScanResponse:
			return AdvertisementTypeArgs::kScanResponse;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::Extended:
			return AdvertisementTypeArgs::kExtended;
		default:
			throw std::bad_cast();
		}
	}

	ConnectionStateArgs CentralManagerImpl::ConnectionStatusToArgs(const winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus &status)
	{
		switch (status)
		{
		case winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus::Disconnected:
			return ConnectionStateArgs::kDisconnected;
		case winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus::Connected:
			return ConnectionStateArgs::kConnected;
		default:
			throw std::bad_cast();
		}
	}

	ManufacturerSpecificDataArgs CentralManagerImpl::ManufacturerDataToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEManufacturerData &manufacturer_data)
	{
		const auto id = manufacturer_data.CompanyId();
		const auto id_args = static_cast<int64_t>(id);
		const auto data = manufacturer_data.Data();
		const auto data_length = data.Length();
		auto data_args = std::vector<uint8_t>(data_length);
		const auto data_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(data);
		data_reader.ReadBytes(data_args);
		return ManufacturerSpecificDataArgs(id_args, data_args);
	}

	AdvertisementArgs CentralManagerImpl::AdvertisementToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisement &advertisement)
	{
		const auto name = advertisement.LocalName();
		const auto name_args = winrt::to_string(name);
		const auto service_uuids = advertisement.ServiceUuids();
		auto service_uuids_args = flutter::EncodableList();
		for (const auto &service_uuid : service_uuids)
		{
			const auto service_uuid_args = GUIDToArgs(service_uuid);
			service_uuids_args.emplace_back(service_uuid_args);
		}
		const auto data_sections = advertisement.DataSections();
		auto service_data_args = flutter::EncodableMap();
		for (const auto data_section : data_sections)
		{
			const auto section_type = data_section.DataType();
			const auto section_buffer = data_section.Data();
			const auto section_data_length = section_buffer.Length();
			const auto type16 = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementDataTypes::ServiceData16BitUuids();
			const auto type32 = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementDataTypes::ServiceData32BitUuids();
			const auto type128 = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementDataTypes::ServiceData128BitUuids();
			if (section_type == type16 && section_data_length > 2)
			{
				const auto section_data = section_buffer.data();
				auto data1 = uint16_t();
				std::memcpy(&data1, section_data, 2Ui64);
				const auto uuid_args = std::format("{:04X}", data1);
				const auto data_args = std::vector<uint8_t>(section_data + 2, section_data + section_data_length);
				service_data_args[uuid_args] = data_args;
			}
			else if (section_type == type32 && section_data_length > 4)
			{
				const auto section_data = section_buffer.data();
				auto data1 = uint32_t();
				std::memcpy(&data1, section_data, 4Ui64);
				const auto uuid_args = std::format("{:08X}", data1);
				const auto data_args = std::vector<uint8_t>(section_data + 4, section_data + section_data_length);
				service_data_args[uuid_args] = data_args;
			}
			else if (section_type == type128 && section_data_length > 16)
			{
				const auto section_data = section_buffer.data();
				auto data1 = uint32_t();
				std::memcpy(&data1, section_data, 4Ui64);
				auto data2 = uint16_t();
				std::memcpy(&data2, section_data + 4, 2Ui64);
				auto data3 = uint16_t();
				std::memcpy(&data3, section_data + 6, 2Ui64);
				auto data4 = std::array<uint8_t, 8Ui64>();
				std::memcpy(&data4, section_data + 8, 8Ui64);
				const auto uuid = winrt::guid(data1, data2, data3, data4);
				const auto uuid_args = GUIDToArgs(uuid);
				const auto data_args = std::vector<uint8_t>(section_data + 16, section_data + section_data_length);
				service_data_args[uuid_args] = data_args;
			}
		}
		const auto manufacturer_data = advertisement.ManufacturerData();
		auto manufacturer_specific_data_args = flutter::EncodableList();
		for (const auto &data : manufacturer_data)
		{
			const auto data_args = ManufacturerDataToArgs(data);
			const auto data_args_value = flutter::CustomEncodableValue(data_args);
			manufacturer_specific_data_args.emplace_back(data_args_value);
		}
		return AdvertisementArgs(&name_args, service_uuids_args, service_data_args, manufacturer_specific_data_args);
	}

	GATTServiceArgs CentralManagerImpl::ServiceToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService &service)
	{
		const auto handle = service.AttributeHandle();
		const auto handle_args = static_cast<int64_t>(handle);
		const auto uuid = service.Uuid();
		const auto uuid_args = GUIDToArgs(uuid);
		const auto is_primary_args = true;
		const auto included_services_args = flutter::EncodableList();
		const auto characteristics_args = flutter::EncodableList();
		return GATTServiceArgs(handle_args, uuid_args, is_primary_args, included_services_args, characteristics_args);
	}

	GATTCharacteristicArgs CentralManagerImpl::CharacteristicToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &characteristic)
	{
		const auto handle = characteristic.AttributeHandle();
		const auto handle_args = static_cast<int64_t>(handle);
		const auto uuid = characteristic.Uuid();
		const auto uuid_args = GUIDToArgs(uuid);
		const auto properties = characteristic.CharacteristicProperties();
		const auto property_numbers_args = CharacteristicPropertiesToArgs(properties);
		const auto descriptors_args = flutter::EncodableList();
		return GATTCharacteristicArgs(handle_args, uuid_args, property_numbers_args, descriptors_args);
	}

	flutter::EncodableList CentralManagerImpl::CharacteristicPropertiesToArgs(winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties properties)
	{
		const auto readable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Read);
		const auto writable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Write);
		const auto writableWithoutResponse = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::WriteWithoutResponse);
		const auto notifiable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Notify);
		const auto indicatable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Indicate);
		auto property_numbers_args = flutter::EncodableList();
		if (readable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kRead);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (writable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kWrite);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (writableWithoutResponse)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kWriteWithoutResponse);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (notifiable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kNotify);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (indicatable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kIndicate);
			property_numbers_args.emplace_back(property_number_args);
		}
		return property_numbers_args;
	}

	GATTDescriptorArgs CentralManagerImpl::DescriptorToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDescriptor &descriptor)
	{
		const auto handle = descriptor.AttributeHandle();
		const auto handle_args = static_cast<int64_t>(handle);
		const auto uuid = descriptor.Uuid();
		const auto uuid_args = GUIDToArgs(uuid);
		return GATTDescriptorArgs(handle_args, uuid_args);
	}

	std::string CentralManagerImpl::GUIDToArgs(const winrt::guid &guid)
	{
		// const auto uuid_value = winrt::to_hstring(uuid);
		// return winrt::to_string(uuid_value);
		return std::format("{}", guid);
	}

	winrt::Windows::Devices::Bluetooth::BluetoothCacheMode CentralManagerImpl::ArgsToCacheMode(const CacheModeArgs &mode_args)
	{
		switch (mode_args)
		{
		case CacheModeArgs::kCached:
			return winrt::Windows::Devices::Bluetooth::BluetoothCacheMode::Cached;
		case CacheModeArgs::kUncached:
			return winrt::Windows::Devices::Bluetooth::BluetoothCacheMode::Uncached;
		default:
			throw std::bad_cast();
		}
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption CentralManagerImpl::ArgsToWriteOption(const GATTCharacteristicWriteTypeArgs &type_args)
	{
		switch (type_args)
		{
		case GATTCharacteristicWriteTypeArgs::kWithoutResponse:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption::WriteWithoutResponse;
		case GATTCharacteristicWriteTypeArgs::kWithResponse:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption::WriteWithResponse;
		default:
			throw std::bad_cast();
		}
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue CentralManagerImpl::ArgsToCCCDescriptorValue(const GATTCharacteristicNotifyStateArgs &state_args)
	{
		switch (state_args)
		{
		case GATTCharacteristicNotifyStateArgs::kNone:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue::None;
		case GATTCharacteristicNotifyStateArgs::kNotify:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue::Notify;
		case GATTCharacteristicNotifyStateArgs::kIndicate:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue::Indicate;
		default:
			throw std::bad_cast();
		}
	}
}
