#ifndef FLUTTER_PLUGIN_CENTRAL_MANAGER_H_
#define FLUTTER_PLUGIN_CENTRAL_MANAGER_H_

#include <atomic>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <sstream>

#include "winrt/Windows.Devices.Bluetooth.h"
#include "winrt/Windows.Devices.Bluetooth.Advertisement.h"
#include "winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h"
#include "winrt/Windows.Devices.Radios.h"
#include "winrt/Windows.Foundation.h"
#include "winrt/Windows.Foundation.Metadata.h"
#include "winrt/Windows.Foundation.Collections.h"
#include "winrt/Windows.Storage.Streams.h"

#include "bluetooth_low_energy_api.g.h"
#include "bluetooth_low_energy_exception.h"
#include "bluetooth_low_energy_format.h"
#include "ui_thread.h"

namespace bluetooth_low_energy_windows
{
	class CentralManagerImpl : public CentralManagerHostApi
	{
	public:
		CentralManagerImpl(flutter::BinaryMessenger *messenger);
		virtual ~CentralManagerImpl();

		// Disallow copy and assign.
		CentralManagerImpl(const CentralManagerImpl &) = delete;
		CentralManagerImpl &operator=(const CentralManagerImpl &) = delete;

		void Initialize(std::function<void(std::optional<FlutterError> reply)> result) override;
		ErrorOr<BluetoothLowEnergyStateArgs> GetState() override;
		std::optional<FlutterError> StartDiscovery(const flutter::EncodableList &service_uuids_args) override;
		std::optional<FlutterError> StopDiscovery() override;
		void Connect(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result) override;
		std::optional<FlutterError> Disconnect(int64_t address_args) override;
		ErrorOr<int64_t> GetMTU(int64_t address_args) override;
		void GetServices(int64_t address_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result) override;
		void GetIncludedServices(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result) override;
		void GetCharacteristics(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result) override;
		void GetDescriptors(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result) override;
		void ReadCharacteristic(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result) override;
		void WriteCharacteristic(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, const GATTCharacteristicWriteTypeArgs &type_args, std::function<void(std::optional<FlutterError> reply)> result) override;
		void SetCharacteristicNotifyState(int64_t address_args, int64_t handle_args, const GATTCharacteristicNotifyStateArgs &state_args, std::function<void(std::optional<FlutterError> reply)> result) override;
		void ReadDescriptor(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result) override;
		void WriteDescriptor(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result) override;

	private:
		// Captured on the platform thread at construction; used to marshal
		// pigeon calls/results back from thread-pool continuations.
		winrt::apartment_context m_ui_context;
		std::optional<CentralManagerFlutterApi> m_api;
		std::optional<winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher> m_watcher;
		std::optional<winrt::Windows::Devices::Bluetooth::BluetoothAdapter> m_adapter;
		std::optional<winrt::Windows::Devices::Radios::Radio> m_radio;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::BluetoothLEDevice>> m_devices;
		// Address type (public/random) observed while scanning; required to
		// connect to peripherals that use random addressing (macOS/iOS).
		std::map<int64_t, winrt::Windows::Devices::Bluetooth::BluetoothAddressType> m_address_types;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession>> m_sessions;
		std::map<int64_t, std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService>>> m_services;
		std::map<int64_t, std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic>>> m_characteristics;
		std::map<int64_t, std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDescriptor>>> m_descriptors;
		std::optional<winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher::Received_revoker> m_watcher_received_revoker;
		// Set between StartDiscovery and StopDiscovery. Windows can stop the
		// watcher on its own (radio busy, adapter reset) without the app
		// asking; while this is set it gets started again.
		std::atomic<bool> m_discovering{false};
		std::optional<winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher::Stopped_revoker> m_watcher_stopped_revoker;
		// Tells "Windows hears nothing" apart from "the app never gets what
		// Windows hears" in the log.
		std::atomic<int64_t> m_adverts_received{0};
		std::atomic<bool> m_reported_first_delivery{false};
		// Writes without response mean a bulk transfer: ask Windows 11 for
		// its fast connection timing, and let go after a few idle seconds
		// (it costs both devices power).
		std::map<int64_t, winrt::Windows::Foundation::IClosable> m_throughput_requests;
		std::map<int64_t, std::chrono::steady_clock::time_point> m_last_bulk_write;
		// Notifications from each peripheral in the current second.
		std::map<int64_t, std::pair<std::chrono::steady_clock::time_point, int>> m_notification_bursts;
		std::optional<winrt::Windows::Devices::Radios::Radio::StateChanged_revoker> m_radio_state_changed_revoker;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::ConnectionStatusChanged_revoker>> m_device_connection_status_changed_revokers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession::MaxPduSizeChanged_revoker>> m_session_max_pdu_size_changed_revokers;
		std::map<int64_t, std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic::ValueChanged_revoker>>> m_characteristic_value_changed_revokers;

		winrt::fire_and_forget InitializeAsync(std::function<void(std::optional<FlutterError> reply)> result);
		winrt::fire_and_forget RestartDiscoveryAsync(winrt::Windows::Foundation::TimeSpan delay);
		winrt::fire_and_forget ConnectAsync(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result);
		winrt::fire_and_forget GetServicesAsync(int64_t address_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result);
		winrt::fire_and_forget GetIncludedServicesAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result);
		winrt::fire_and_forget GetCharacteristicsAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result);
		winrt::fire_and_forget GetDescriptorsAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result);
		winrt::fire_and_forget ReadCharacteristicAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result);
		winrt::fire_and_forget WriteCharacteristicAsync(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, const GATTCharacteristicWriteTypeArgs &type_args, std::function<void(std::optional<FlutterError> reply)> result);
		winrt::fire_and_forget SetCharacteristicNotifyStateAsync(int64_t address_args, int64_t handle_args, const GATTCharacteristicNotifyStateArgs &state_args, std::function<void(std::optional<FlutterError> reply)> result);
		winrt::fire_and_forget ReadDescriptorAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result);
		winrt::fire_and_forget WriteDescriptorAsync(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result);

		void OnDisconnected(int64_t address_args);
		void CloseConnection(int64_t address_args);
		void RequestThroughput(int64_t address_args);
		void ReleaseThroughput(int64_t address_args);
		void NoteNotification(int64_t address_args);
		winrt::fire_and_forget ReleaseThroughputWhenIdleAsync(int64_t address_args);

		winrt::Windows::Devices::Bluetooth::BluetoothLEDevice &RetrieveDevice(int64_t address_args);
		winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService &RetrieveService(int64_t address_args, int64_t handle_args);
		winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &RetrieveCharacteristic(int64_t address, int64_t handle_args);
		winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDescriptor &RetrieveDescriptor(int64_t address_args, int64_t handle_args);

		BluetoothLowEnergyStateArgs RadioStateToArgs(const winrt::Windows::Devices::Radios::RadioState &state);
		AdvertisementTypeArgs AdvertisementTypeToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType &type);
		ConnectionStateArgs ConnectionStatusToArgs(const winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus &status);
		ManufacturerSpecificDataArgs ManufacturerDataToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEManufacturerData &manufacturer_data);
		AdvertisementArgs AdvertisementToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisement &advertisement);
		GATTServiceArgs ServiceToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService &service);
		GATTCharacteristicArgs CharacteristicToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &characteristic);
		flutter::EncodableList CharacteristicPropertiesToArgs(winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties properties);
		GATTDescriptorArgs DescriptorToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDescriptor &descriptor);
		std::string GUIDToArgs(const winrt::guid &guid);

		winrt::Windows::Devices::Bluetooth::BluetoothCacheMode ArgsToCacheMode(const CacheModeArgs &mode_args);
		winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption ArgsToWriteOption(const GATTCharacteristicWriteTypeArgs &type_args);
		winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue ArgsToCCCDescriptorValue(const GATTCharacteristicNotifyStateArgs &state_args);
	};
}

#endif // !FLUTTER_PLUGIN_CENTRAL_MANAGER_H_
