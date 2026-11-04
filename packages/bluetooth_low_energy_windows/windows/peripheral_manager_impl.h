#ifndef FLUTTER_PLUGIN_PERIPHERAL_MANAGER_H_
#define FLUTTER_PLUGIN_PERIPHERAL_MANAGER_H_

#include <atomic>
#include <functional>
#include <map>
#include <mutex>

#include "winrt/Windows.Devices.Bluetooth.h"
#include "winrt/Windows.Devices.Bluetooth.Advertisement.h"
#include "winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h"
#include "winrt/Windows.Devices.Radios.h"
#include "winrt/Windows.Foundation.h"
#include "winrt/Windows.Foundation.Collections.h"
#include "winrt/Windows.Storage.Streams.h"

#include "bluetooth_low_energy_api.g.h"
#include "bluetooth_low_energy_exception.h"
#include "ui_thread.h"

namespace bluetooth_low_energy_windows
{
	class PeripheralManagerImpl : public PeripheralManagerHostApi
	{
	public:
		PeripheralManagerImpl(flutter::BinaryMessenger *messenger);
		virtual ~PeripheralManagerImpl();

		// Disallow copy and assign.
		PeripheralManagerImpl(const PeripheralManagerImpl &) = delete;
		PeripheralManagerImpl &operator=(const PeripheralManagerImpl &) = delete;

		void Initialize(std::function<void(std::optional<FlutterError> reply)> result) override;
		ErrorOr<BluetoothLowEnergyStateArgs> GetState() override;
		void AddService(const MutableGATTServiceArgs &service_args, std::function<void(std::optional<FlutterError> reply)> result) override;
		std::optional<FlutterError> RemoveService(int64_t hash_code_args) override;
		std::optional<FlutterError> StartAdvertising(const AdvertisementArgs &advertisement_args) override;
		std::optional<FlutterError> StopAdvertising() override;
		ErrorOr<int64_t> GetMaxNotificationSize(int64_t address_args) override;
		std::optional<FlutterError> RespondReadRequestWithValue(int64_t id_args, const std::vector<uint8_t> &value_args) override;
		std::optional<FlutterError> RespondReadRequestWithProtocolError(int64_t id_args, const GATTProtocolErrorArgs &error_args) override;
		std::optional<FlutterError> RespondWriteRequest(int64_t id_args) override;
		std::optional<FlutterError> RespondWriteRequestWithProtocolError(int64_t id_args, const GATTProtocolErrorArgs &error_args) override;
		void NotifyValue(int64_t address_args, int64_t hash_code_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result) override;

	private:
		// Captured on the platform thread at construction; used to marshal
		// pigeon calls/results back from thread-pool continuations.
		winrt::apartment_context m_ui_context;
		std::optional<PeripheralManagerFlutterApi> m_api;
		std::optional<winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementPublisher> m_publisher;
		std::optional<winrt::Windows::Devices::Bluetooth::BluetoothAdapter> m_adapter;
		std::optional<winrt::Windows::Devices::Radios::Radio> m_radio;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSubscribedClient>> m_clients;
		std::map<int64_t, std::optional<MutableGATTServiceArgs>> m_services_args;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattServiceProvider>> m_service_providers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattServiceProvider::AdvertisementStatusChanged_revoker>> m_service_provider_advertisement_status_changed_revokers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic>> m_characteristics;
		std::map<int64_t, std::optional<winrt::Windows::Foundation::Deferral>> m_deferrals;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattReadRequest>> m_read_requests;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteRequest>> m_write_requests;

		std::optional<winrt::Windows::Devices::Radios::Radio::StateChanged_revoker> m_radio_state_changed_revoker;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession::MaxPduSizeChanged_revoker>> m_session_max_pdu_size_changed_revokers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic::ReadRequested_revoker>> m_characteristic_read_requested_revokers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic::WriteRequested_revoker>> m_characteristic_write_requested_revokers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic::SubscribedClientsChanged_revoker>> m_characteristic_subscribed_clients_changed_revokers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalDescriptor::ReadRequested_revoker>> m_descriptor_read_requested_revokers;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalDescriptor::WriteRequested_revoker>> m_descriptor_write_requested_revokers;

		// Writes without response arrive back to back, and the lookups each
		// one needs can finish out of order. Every characteristic write takes
		// a ticket in the order Windows raised it, and reaches the app
		// strictly in ticket order.
		std::atomic<uint64_t> m_next_write_ticket{0};
		uint64_t m_next_write_delivery = 0;
		std::map<uint64_t, std::function<void()>> m_pending_writes;
		// Ids for read and write requests awaiting Dart's answer.
		std::atomic<int64_t> m_next_request_id{1};
		// Device id -> Bluetooth address; looking it up for every write
		// costs a round trip through the Bluetooth stack.
		std::mutex m_addresses_mutex;
		std::map<winrt::hstring, int64_t> m_addresses;
		std::map<int64_t, std::optional<winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession>> m_watched_sessions;

		void DeliverWriteInOrder(uint64_t ticket, std::function<void()> deliver);
		// The Bluetooth address behind [session]; throws when the device is
		// already gone (a request arriving as it disconnects).
		winrt::Windows::Foundation::IAsyncOperation<int64_t> AddressOfAsync(winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession session);
		void WatchMtu(int64_t address_args, const CentralArgs &central_args, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession &session);

		winrt::fire_and_forget InitializeAsync(std::function<void(std::optional<FlutterError> reply)> result);
		winrt::fire_and_forget AddServiceAsync(const MutableGATTServiceArgs &service_args, std::function<void(std::optional<FlutterError> reply)> result);
		winrt::fire_and_forget NotifyValueAsync(int64_t address_args, int64_t hash_code_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result);
		winrt::fire_and_forget RestartAdvertisingAsync(int64_t hash_code_args, winrt::Windows::Foundation::TimeSpan delay);
		static winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattServiceProviderAdvertisingParameters AdvertisingParameters();

		winrt::Windows::Foundation::IAsyncAction CreateServiceAsync(const MutableGATTServiceArgs service_args);
		winrt::Windows::Foundation::IAsyncAction CreateCharacteristicAsync(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalService &service, const MutableGATTCharacteristicArgs characteristic_args);
		winrt::Windows::Foundation::IAsyncAction CreateDescriptorAsync(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic &characteristic, const MutableGATTDescriptorArgs descriptor_args);

		void RemoveServiceArgs(const MutableGATTServiceArgs &service_args);
		void RemoveCharacteristicArgs(const MutableGATTCharacteristicArgs &characteristic_args);
		void RemoveDescriptorArgs(const MutableGATTDescriptorArgs &descriptor_args);

		winrt::fire_and_forget OnCharacteristicReadRequestedAsync(const int64_t hash_code_args, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattReadRequestedEventArgs event_args);
		winrt::fire_and_forget OnCharacteristicWriteRequestedAsync(const int64_t hash_code_args, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteRequestedEventArgs event_args);
		winrt::fire_and_forget OnCharacteristicSubscribedClientsChangedAsync(const int64_t hash_code_args, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic &characteristic);
		winrt::fire_and_forget OnDescriptorReadRequestedAsync(const int64_t hash_code_args, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattReadRequestedEventArgs event_args);
		winrt::fire_and_forget OnDescriptorWriteRequestedAsync(const int64_t hash_code_args, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteRequestedEventArgs event_args);

		BluetoothLowEnergyStateArgs RadioStateToArgs(const winrt::Windows::Devices::Radios::RadioState &state);
		GATTCharacteristicWriteTypeArgs WriteOptionToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption &option);

		winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEManufacturerData ArgsToManufacturerData(const ManufacturerSpecificDataArgs &manufacturer_specific_data_args);
		winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties ArgsToCharacteristicProperties(const flutter::EncodableList property_numbers_args);
		winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattProtectionLevel ArgsToProtectionLevel(const GATTProtectionLevelArgs &level_args);
		uint8_t ArgsToProtocolError(const GATTProtocolErrorArgs &error_args);
	};

} // namespace bluetooth_low_energy_windows

#endif // FLUTTER_PLUGIN_PERIPHERAL_MANAGER_H_
