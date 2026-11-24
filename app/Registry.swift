// Registry reads for the RMNet app: the modem on USB and the driver's RMNet* properties.
// Read only; nothing is opened.
import Foundation
import IOKit

let driverClass = "RMNetDriver"  // the driver's IOUserClass
let modemVendor = 0x2C7C  // the products are in quectelModels (StatusModel.swift)

func properties(of entry: io_registry_entry_t) -> [String: Any] {
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
    return dict
}

// The first service of class `className` whose properties include all of `match`.
func firstService(_ className: String, withProperties match: [String: Any]) -> io_service_t {
    let matching = IOServiceMatching(className) as NSMutableDictionary
    matching[kIOPropertyMatchKey] = match
    return IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)  // consumes `matching`
}

func intValue(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

// Whether a modem from quectelModels is attached (the first the list names, if several are), which
// model it is (nil when none is), and whether it is in QMI mode (modemState: its own QMI interface,
// with class, subclass and protocol 0xff and three endpoints), so "not installed", "modem not in QMI
// mode" and "attached" can be told apart.
func readModemModel() -> (state: ModemState, model: QuectelModel?) {
    for model in quectelModels {
        let device = firstService("IOUSBHostDevice", withProperties: ["idVendor": modemVendor, "idProduct": model.product])
        guard device != IO_OBJECT_NULL else { continue }
        defer { IOObjectRelease(device) }

        var interfaces: [UsbInterface] = []
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS {
            var child = IOIteratorNext(children)
            while child != IO_OBJECT_NULL {
                let p = properties(of: child)
                interfaces.append(UsbInterface(number: intValue(p["bInterfaceNumber"]),
                                               interfaceClass: intValue(p["bInterfaceClass"]),
                                               subclass: intValue(p["bInterfaceSubClass"]),
                                               proto: intValue(p["bInterfaceProtocol"]),
                                               endpoints: intValue(p["bNumEndpoints"])))
                IOObjectRelease(child)
                child = IOIteratorNext(children)
            }
            IOObjectRelease(children)
        }
        return (modemState(model, interfaces: interfaces), model)
    }
    return (.absent, nil)
}

// The RMNet* properties of the driver's registry entry, as strings, or nil if it is not attached.
func readDriverProperties() -> [String: String]? {
    let entry = firstService("IOService", withProperties: ["IOUserClass": driverClass])
    guard entry != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(entry) }
    var result: [String: String] = [:]
    for (key, value) in properties(of: entry) where key.hasPrefix("RMNet") {
        result[key] = propertyString(value)
    }
    return result
}

// The status the window and `status --json` show, with the entries a properties request listed.
func readStatus(entries: [ExtensionEntry]) -> DriverStatus {
    let driver = readDriverProperties()
    let (modem, model) = readModemModel()
    return DriverStatus(entries: entries, modem: modem, modemModel: model, attached: driver != nil,
                        properties: driver ?? [:])
}

// The attached modem's USB serial number (its "USB Serial Number" property, as `ioreg` shows it), nil when none of
// quectelModels is attached or it gives none. An IMEI change does not touch it, so the IMEI history tells modules apart
// by it (ImeiHistory.swift).
func readModemSerial() -> String? {
    for model in quectelModels {
        let device = firstService("IOUSBHostDevice", withProperties: ["idVendor": modemVendor, "idProduct": model.product])
        guard device != IO_OBJECT_NULL else { continue }
        defer { IOObjectRelease(device) }
        let p = properties(of: device)
        let serial = (p["USB Serial Number"] as? String) ?? (p["kUSBSerialNumberString"] as? String)
        guard let serial, !serial.isEmpty else { return nil }
        return String(serial.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }.prefix(64))
    }
    return nil
}
