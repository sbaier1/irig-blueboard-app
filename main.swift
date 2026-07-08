import Cocoa
import CoreBluetooth
import CoreMIDI

setbuf(stdout, nil)

// MARK: - Driver Delegate Protocol
protocol BlueBoardDriverDelegate: AnyObject {
    func driverDidUpdateStatus(_ status: String)
    func driverDidUpdateBank(_ bank: UInt8)
    func driverDidUpdateBattery(_ battery: UInt8)
    func driverDidUpdateActiveSwitch(_ index: UInt8?)
    func driverDidUpdatePedal(index: UInt8, rawValue: UInt8, midiValue: UInt8)
    func scalePedalValue(index: UInt8, rawValue: UInt8) -> UInt8
}

// MARK: - BlueBoard Driver Class
class BlueBoardDriver: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var delegate: BlueBoardDriverDelegate?
    
    var centralManager: CBCentralManager!
    var targetPeripheral: CBPeripheral?
    var midiClient = MIDIClientRef()
    var virtualSource = MIDIEndpointRef()
    
    // GATT Service and Characteristic UUIDs
    let serviceUUID = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB00")
    let charSwitches      = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB01")
    let charLeds          = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB02")
    let charExtSwitches   = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB03")
    let charConnParams    = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB04")
    let charBacklight     = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB05")
    let charLedsStatus    = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB06")
    let charSynch         = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB07")
    let charRename        = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB08")
    let charValidation    = CBUUID(string: "6B872736-F93E-4176-B3B1-143636CABB09")
    
    // Handshake XOR key
    let xorKey: [UInt8] = [
        0xf2, 0x63, 0xee, 0xb6, 0xa7, 0x12, 0x05, 0x50,
        0xb1, 0x57, 0x21, 0x6a, 0x2e, 0xfa, 0xc3, 0x9c,
        0x7d, 0xb7, 0x76, 0xbc
    ]
    
    // Driver state
    var currentBank: UInt8 = 0
    var activeLed: UInt8? = 0 // Keep LED A lit initially
    var pressTimes: [UInt8: Date] = [:]
    
    init(delegate: BlueBoardDriverDelegate) {
        super.init()
        self.delegate = delegate
        setupMIDI()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - MIDI Setup
    func setupMIDI() {
        var status = MIDIClientCreate("iRigBlueBoardClient" as CFString, nil, nil, &midiClient)
        if status != noErr {
            print("Error creating MIDI client: \(status)")
        }
        
        status = MIDISourceCreateWithProtocol(midiClient, "iRig BlueBoard" as CFString, MIDIProtocolID._1_0, &virtualSource)
        if status != noErr {
            print("Error creating Virtual MIDI Source: \(status)")
        } else {
            print("Virtual MIDI Source 'iRig BlueBoard' created successfully.")
        }
    }
    
    func sendUMP(statusByte: UInt8, data1: UInt8, data2: UInt8) {
        let word: UInt32 = 0x20000000 | (UInt32(statusByte) << 16) | (UInt32(data1) << 8) | UInt32(data2)
        
        var event = MIDIEventPacket()
        event.timeStamp = 0 // Immediate
        event.wordCount = 1
        event.words.0 = word
        
        var eventList = MIDIEventList(protocol: MIDIProtocolID._1_0, numPackets: 1, packet: event)
        MIDIReceivedEventList(virtualSource, &eventList)
    }
    
    func sendProgramChangeToAllChannels(program: UInt8) {
        for channel in 0..<16 {
            let statusByte: UInt8 = 0xC0 | UInt8(channel)
            sendUMP(statusByte: statusByte, data1: program, data2: 0)
        }
        print("Sent MIDI Program Change \(program) to all channels.")
    }
    
    func sendControlChangeToAllChannels(cc: UInt8, value: UInt8) {
        for channel in 0..<16 {
            let statusByte: UInt8 = 0xB0 | UInt8(channel)
            sendUMP(statusByte: statusByte, data1: cc, data2: value)
        }
    }
    
    // MARK: - Bluetooth Central Manager Delegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            delegate?.driverDidUpdateStatus("Bluetooth Disabled")
            return
        }
        
        delegate?.driverDidUpdateStatus("Scanning...")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        if name.lowercased().contains("blueboard") {
            print("Discovered BlueBoard: \(name) [\(peripheral.identifier)]. Connecting...")
            delegate?.driverDidUpdateStatus("Connecting...")
            centralManager.stopScan()
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to iRig BlueBoard!")
        delegate?.driverDidUpdateStatus("Authenticating...")
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected: \(String(describing: error))")
        delegate?.driverDidUpdateStatus("Scanning...")
        delegate?.driverDidUpdateBattery(0)
        delegate?.driverDidUpdateActiveSwitch(nil)
        targetPeripheral = nil
        pressTimes.removeAll()
        
        DispatchQueue.main.async {
            self.delegate?.driverDidUpdatePedal(index: 0, rawValue: 0, midiValue: 0)
            self.delegate?.driverDidUpdatePedal(index: 1, rawValue: 0, midiValue: 0)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.targetPeripheral == nil {
                self.centralManager.scanForPeripherals(withServices: nil, options: nil)
            }
        }
    }
    
    // MARK: - CBPeripheral Delegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error)")
            return
        }
        
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error discovering characteristics for \(service.uuid): \(error)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        if service.uuid == serviceUUID {
            if let charVal = characteristics.first(where: { $0.uuid == charValidation }) {
                peripheral.readValue(for: charVal)
            }
        } else if service.uuid == CBUUID(string: "180F") { // Battery
            if let charBat = characteristics.first(where: { $0.properties.contains(.read) }) {
                peripheral.readValue(for: charBat)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating value for \(characteristic.uuid.uuidString.suffix(4)): \(error)")
            return
        }
        
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == charValidation {
            var responseBytes = [UInt8](repeating: 0, count: 20)
            data.withUnsafeBytes { (challengePtr: UnsafeRawBufferPointer) in
                for i in 0..<20 {
                    responseBytes[i] = challengePtr[i] ^ xorKey[i]
                }
            }
            
            let responseData = Data(responseBytes)
            peripheral.writeValue(responseData, for: characteristic, type: .withResponse)
            
        } else if characteristic.uuid == CBUUID(string: "2A19") { // Battery Level
            if let batVal = data.first {
                print("Battery level updated: \(batVal)%")
                delegate?.driverDidUpdateBattery(batVal)
            }
        } else if characteristic.uuid == charSwitches {
            // BUTTON EVENT: 2 bytes [button_index, value]
            guard data.count >= 2 else { return }
            let btnIndex = data[0]
            let btnValue = data[1]
            let isPressed = (btnValue == 0xFF)
            
            handleButtonEvent(index: btnIndex, pressed: isPressed)
            
        } else if characteristic.uuid == charExtSwitches {
            // EXPRESSION PEDAL EVENT: 2 bytes [pedal_index, value]
            guard data.count >= 2 else { return }
            let pedalIndex = data[0]
            let valByte = data[1]
            
            let midiVal = delegate?.scalePedalValue(index: pedalIndex, rawValue: valByte) ?? UInt8(round(Double(valByte) * 127.0 / 255.0))
            let ccNumber: UInt8 = (pedalIndex == 0) ? 7 : 11
            sendControlChangeToAllChannels(cc: ccNumber, value: midiVal)
            
            delegate?.driverDidUpdatePedal(index: pedalIndex, rawValue: valByte, midiValue: midiVal)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error writing to \(characteristic.uuid.uuidString.suffix(4)): \(error)")
            return
        }
        
        if characteristic.uuid == charValidation {
            print("Handshake successful! Activating inputs...")
            delegate?.driverDidUpdateStatus("Connected")
            
            guard let service = targetPeripheral?.services?.first(where: { $0.uuid == serviceUUID }),
                  let characteristics = service.characteristics else { return }
            
            // Subscribe to notifications
            let notifyUUIDs = [charSwitches, charExtSwitches, charSynch]
            for uuid in notifyUUIDs {
                if let char = characteristics.first(where: { $0.uuid == uuid }) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
            
            // Enable backlight
            if let charBack = characteristics.first(where: { $0.uuid == charBacklight }) {
                peripheral.writeValue(Data([0x01]), for: charBack, type: .withResponse)
            }
            
            updateLEDs()
            delegate?.driverDidUpdateActiveSwitch(activeLed)
        }
    }
    
    // MARK: - Buttons and LEDs Logic
    func handleButtonEvent(index: UInt8, pressed: Bool) {
        if pressed {
            pressTimes[index] = Date()
        } else {
            let pressTime = pressTimes[index] ?? Date()
            let duration = Date().timeIntervalSince(pressTime)
            pressTimes.removeValue(forKey: index)
            
            // BANK UP: Button A held >= 3.0s
            if index == 0 && duration >= 3.0 {
                currentBank = (currentBank + 1) % 32
                delegate?.driverDidUpdateBank(currentBank)
                flashLEDsConfirm()
                return
            }
            
            // BANK DOWN: Button B held >= 3.0s
            if index == 1 && duration >= 3.0 {
                currentBank = (currentBank > 0) ? (currentBank - 1) : 31
                delegate?.driverDidUpdateBank(currentBank)
                flashLEDsConfirm()
                return
            }
            
            // STANDARD PRESS: send Program Change
            let programNumber = (currentBank * 4) + index
            sendProgramChangeToAllChannels(program: programNumber)
            
            activeLed = index
            updateLEDs()
            delegate?.driverDidUpdateActiveSwitch(index)
        }
    }
    
    func updateLEDs() {
        guard let p = targetPeripheral,
              let service = p.services?.first(where: { $0.uuid == serviceUUID }),
              let characteristics = service.characteristics,
              let charL = characteristics.first(where: { $0.uuid == charLeds }) else { return }
        
        for i in UInt8(0)...UInt8(3) {
            let status: UInt8 = (i == activeLed) ? 0xFF : 0x00
            p.writeValue(Data([i, status]), for: charL, type: .withResponse)
        }
    }
    
    func flashLEDsConfirm() {
        guard let p = targetPeripheral,
              let service = p.services?.first(where: { $0.uuid == serviceUUID }),
              let characteristics = service.characteristics,
              let charL = characteristics.first(where: { $0.uuid == charLeds }) else { return }
        
        for i in UInt8(0)...UInt8(3) {
            p.writeValue(Data([i, 0xFF]), for: charL, type: .withResponse)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for i in UInt8(0)...UInt8(3) {
                p.writeValue(Data([i, 0x00]), for: charL, type: .withResponse)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.updateLEDs()
            }
        }
    }
}

// MARK: - App Delegate for standard GUI Window
class AppDelegate: NSObject, NSApplicationDelegate, BlueBoardDriverDelegate {
    var window: NSWindow!
    var driver: BlueBoardDriver!
    
    // UI Elements
    var statusLabel: NSTextField!
    var bankLabel: NSTextField!
    var batteryLabel: NSTextField!
    var switchIndicators: [NSTextField] = []
    
    var pedal1Label: NSTextField!
    var pedal1Indicator: NSProgressIndicator!
    var pedal1RangeLabel: NSTextField!
    var pedal1InvertCheckbox: NSButton!
    
    var pedal2Label: NSTextField!
    var pedal2Indicator: NSProgressIndicator!
    var pedal2RangeLabel: NSTextField!
    var pedal2InvertCheckbox: NSButton!
    
    // Calibration State
    var isCalibratingPedal1 = false
    var tempMin1: UInt8 = 255
    var tempMax1: UInt8 = 0
    var pedal1Min: UInt8 = 0
    var pedal1Max: UInt8 = 255
    var isPedal1Inverted = false
    
    var isCalibratingPedal2 = false
    var tempMin2: UInt8 = 255
    var tempMax2: UInt8 = 0
    var pedal2Min: UInt8 = 0
    var pedal2Max: UInt8 = 255
    var isPedal2Inverted = false
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        loadCalibrationSettings()
        buildGUI()
        driver = BlueBoardDriver(delegate: self)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    // MARK: - Persist Calibration & Invert Settings
    func loadCalibrationSettings() {
        let defaults = UserDefaults.standard
        if let val = defaults.object(forKey: "pedal1Min") as? Int { pedal1Min = UInt8(val) } else { pedal1Min = 0 }
        if let val = defaults.object(forKey: "pedal1Max") as? Int { pedal1Max = UInt8(val) } else { pedal1Max = 255 }
        isPedal1Inverted = defaults.bool(forKey: "pedal1Inverted")
        
        if let val = defaults.object(forKey: "pedal2Min") as? Int { pedal2Min = UInt8(val) } else { pedal2Min = 0 }
        if let val = defaults.object(forKey: "pedal2Max") as? Int { pedal2Max = UInt8(val) } else { pedal2Max = 255 }
        isPedal2Inverted = defaults.bool(forKey: "pedal2Inverted")
    }
    
    // MARK: - Build GUI Layout Programmatically
    func buildGUI() {
        let width: CGFloat = 450
        let height: CGFloat = 380
        
        // Configure main Window
        let windowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: windowStyle,
                          backing: .buffered,
                          defer: false)
        window.center()
        window.title = "iRig BlueBoard Controller"
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.makeKeyAndOrderFront(nil)
        
        // Root container (StackView)
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(mainStack)
        
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
                mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
            ])
        }
        
        // 1. App Title
        let titleLabel = NSTextField(labelWithString: "iRig BlueBoard Replacement")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = NSColor.labelColor
        mainStack.addArrangedSubview(titleLabel)
        
        // 2. Status Indicator
        statusLabel = NSTextField(labelWithString: "Status: Scanning...")
        statusLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textColor = NSColor.systemBlue
        mainStack.addArrangedSubview(statusLabel)
        
        // 3. Info Panel (Bank and Battery)
        let infoStack = NSStackView()
        infoStack.orientation = .horizontal
        infoStack.spacing = 40
        
        bankLabel = NSTextField(labelWithString: "Current Bank: 0 (PC 0 - 3)")
        bankLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        infoStack.addArrangedSubview(bankLabel)
        
        batteryLabel = NSTextField(labelWithString: "Battery: --%")
        batteryLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        infoStack.addArrangedSubview(batteryLabel)
        
        mainStack.addArrangedSubview(infoStack)
        
        // 4. Footswitches Panel (Horizontal Row)
        let switchesStack = NSStackView()
        switchesStack.orientation = .horizontal
        switchesStack.spacing = 12
        
        let switchNames = ["A", "B", "C", "D"]
        for i in 0..<4 {
            let indicator = NSTextField(labelWithString: switchNames[i])
            indicator.font = NSFont.systemFont(ofSize: 16, weight: .bold)
            indicator.alignment = .center
            indicator.textColor = NSColor.white
            indicator.drawsBackground = true
            indicator.backgroundColor = NSColor.darkGray
            indicator.wantsLayer = true
            indicator.layer?.cornerRadius = 8
            
            // Set size constraints
            indicator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                indicator.widthAnchor.constraint(equalToConstant: 45),
                indicator.heightAnchor.constraint(equalToConstant: 45)
            ])
            
            switchesStack.addArrangedSubview(indicator)
            switchIndicators.append(indicator)
        }
        mainStack.addArrangedSubview(switchesStack)
        
        // 5. Expression Pedals Panel
        let pedalsContainer = NSStackView()
        pedalsContainer.orientation = .vertical
        pedalsContainer.alignment = .leading
        pedalsContainer.spacing = 12
        pedalsContainer.translatesAutoresizingMaskIntoConstraints = false
        pedalsContainer.widthAnchor.constraint(equalToConstant: 410).isActive = true
        
        // Pedal 1 Row
        let p1Row = NSStackView()
        p1Row.orientation = .horizontal
        p1Row.spacing = 8
        
        pedal1Label = NSTextField(labelWithString: "Pedal 1 (CC 7): --%")
        pedal1Label.font = NSFont.systemFont(ofSize: 12)
        pedal1Label.translatesAutoresizingMaskIntoConstraints = false
        pedal1Label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        p1Row.addArrangedSubview(pedal1Label)
        
        pedal1Indicator = NSProgressIndicator()
        pedal1Indicator.isIndeterminate = false
        pedal1Indicator.minValue = 0
        pedal1Indicator.maxValue = 255
        pedal1Indicator.doubleValue = 0
        pedal1Indicator.style = .bar
        pedal1Indicator.translatesAutoresizingMaskIntoConstraints = false
        pedal1Indicator.widthAnchor.constraint(equalToConstant: 100).isActive = true
        p1Row.addArrangedSubview(pedal1Indicator)
        
        pedal1RangeLabel = NSTextField(labelWithString: "Range: [\(pedal1Min) - \(pedal1Max)]")
        pedal1RangeLabel.font = NSFont.systemFont(ofSize: 11)
        pedal1RangeLabel.textColor = NSColor.secondaryLabelColor
        pedal1RangeLabel.translatesAutoresizingMaskIntoConstraints = false
        pedal1RangeLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        p1Row.addArrangedSubview(pedal1RangeLabel)
        
        let calBtn1 = NSButton(title: "Calibrate", target: self, action: #selector(calibratePedal1(_:)))
        calBtn1.bezelStyle = .rounded
        calBtn1.translatesAutoresizingMaskIntoConstraints = false
        calBtn1.widthAnchor.constraint(equalToConstant: 60).isActive = true
        p1Row.addArrangedSubview(calBtn1)
        
        pedal1InvertCheckbox = NSButton(checkboxWithTitle: "Invert", target: self, action: #selector(toggleInvertPedal1(_:)))
        pedal1InvertCheckbox.state = isPedal1Inverted ? .on : .off
        pedal1InvertCheckbox.translatesAutoresizingMaskIntoConstraints = false
        pedal1InvertCheckbox.widthAnchor.constraint(equalToConstant: 50).isActive = true
        p1Row.addArrangedSubview(pedal1InvertCheckbox)
        
        pedalsContainer.addArrangedSubview(p1Row)
        
        // Pedal 2 Row
        let p2Row = NSStackView()
        p2Row.orientation = .horizontal
        p2Row.spacing = 8
        
        pedal2Label = NSTextField(labelWithString: "Pedal 2 (CC 11): --%")
        pedal2Label.font = NSFont.systemFont(ofSize: 12)
        pedal2Label.translatesAutoresizingMaskIntoConstraints = false
        pedal2Label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        p2Row.addArrangedSubview(pedal2Label)
        
        pedal2Indicator = NSProgressIndicator()
        pedal2Indicator.isIndeterminate = false
        pedal2Indicator.minValue = 0
        pedal2Indicator.maxValue = 255
        pedal2Indicator.doubleValue = 0
        pedal2Indicator.style = .bar
        pedal2Indicator.translatesAutoresizingMaskIntoConstraints = false
        pedal2Indicator.widthAnchor.constraint(equalToConstant: 100).isActive = true
        p2Row.addArrangedSubview(pedal2Indicator)
        
        pedal2RangeLabel = NSTextField(labelWithString: "Range: [\(pedal2Min) - \(pedal2Max)]")
        pedal2RangeLabel.font = NSFont.systemFont(ofSize: 11)
        pedal2RangeLabel.textColor = NSColor.secondaryLabelColor
        pedal2RangeLabel.translatesAutoresizingMaskIntoConstraints = false
        pedal2RangeLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        p2Row.addArrangedSubview(pedal2RangeLabel)
        
        let calBtn2 = NSButton(title: "Calibrate", target: self, action: #selector(calibratePedal2(_:)))
        calBtn2.bezelStyle = .rounded
        calBtn2.translatesAutoresizingMaskIntoConstraints = false
        calBtn2.widthAnchor.constraint(equalToConstant: 60).isActive = true
        p2Row.addArrangedSubview(calBtn2)
        
        pedal2InvertCheckbox = NSButton(checkboxWithTitle: "Invert", target: self, action: #selector(toggleInvertPedal2(_:)))
        pedal2InvertCheckbox.state = isPedal2Inverted ? .on : .off
        pedal2InvertCheckbox.translatesAutoresizingMaskIntoConstraints = false
        pedal2InvertCheckbox.widthAnchor.constraint(equalToConstant: 50).isActive = true
        p2Row.addArrangedSubview(pedal2InvertCheckbox)
        
        pedalsContainer.addArrangedSubview(p2Row)
        
        mainStack.addArrangedSubview(pedalsContainer)
    }
    
    // MARK: - Invert Checkbox Actions
    @objc func toggleInvertPedal1(_ sender: NSButton) {
        isPedal1Inverted = (sender.state == .on)
        UserDefaults.standard.set(isPedal1Inverted, forKey: "pedal1Inverted")
        print("Pedal 1 Invert: \(isPedal1Inverted)")
    }
    
    @objc func toggleInvertPedal2(_ sender: NSButton) {
        isPedal2Inverted = (sender.state == .on)
        UserDefaults.standard.set(isPedal2Inverted, forKey: "pedal2Inverted")
        print("Pedal 2 Invert: \(isPedal2Inverted)")
    }
    
    // MARK: - Calibration Actions
    @objc func calibratePedal1(_ sender: NSButton) {
        if !isCalibratingPedal1 {
            isCalibratingPedal1 = true
            tempMin1 = 255
            tempMax1 = 0
            sender.title = "Done"
            pedal1RangeLabel.stringValue = "Sweep..."
        } else {
            isCalibratingPedal1 = false
            sender.title = "Calibrate"
            if tempMax1 != tempMin1 { // Actual sweep happened
                if tempMin1 > tempMax1 {
                    // Inverted sweep detected! Automatically check "Invert"
                    pedal1Min = tempMax1
                    pedal1Max = tempMin1
                    isPedal1Inverted = true
                } else {
                    pedal1Min = tempMin1
                    pedal1Max = tempMax1
                    isPedal1Inverted = false
                }
                
                UserDefaults.standard.set(Int(pedal1Min), forKey: "pedal1Min")
                UserDefaults.standard.set(Int(pedal1Max), forKey: "pedal1Max")
                UserDefaults.standard.set(isPedal1Inverted, forKey: "pedal1Inverted")
                
                pedal1InvertCheckbox.state = isPedal1Inverted ? .on : .off
            }
            pedal1RangeLabel.stringValue = "Range: [\(pedal1Min) - \(pedal1Max)]"
        }
    }
    
    @objc func calibratePedal2(_ sender: NSButton) {
        if !isCalibratingPedal2 {
            isCalibratingPedal2 = true
            tempMin2 = 255
            tempMax2 = 0
            sender.title = "Done"
            pedal2RangeLabel.stringValue = "Sweep..."
        } else {
            isCalibratingPedal2 = false
            sender.title = "Calibrate"
            if tempMax2 != tempMin2 { // Actual sweep happened
                if tempMin2 > tempMax2 {
                    // Inverted sweep detected! Automatically check "Invert"
                    pedal2Min = tempMax2
                    pedal2Max = tempMin2
                    isPedal2Inverted = true
                } else {
                    pedal2Min = tempMin2
                    pedal2Max = tempMax2
                    isPedal2Inverted = false
                }
                
                UserDefaults.standard.set(Int(pedal2Min), forKey: "pedal2Min")
                UserDefaults.standard.set(Int(pedal2Max), forKey: "pedal2Max")
                UserDefaults.standard.set(isPedal2Inverted, forKey: "pedal2Inverted")
                
                pedal2InvertCheckbox.state = isPedal2Inverted ? .on : .off
            }
            pedal2RangeLabel.stringValue = "Range: [\(pedal2Min) - \(pedal2Max)]"
        }
    }
    
    // MARK: - Driver Delegate Implementations
    func scalePedalValue(index: UInt8, rawValue: UInt8) -> UInt8 {
        // Collect calibration points live in background if in calibration mode
        if index == 0 && isCalibratingPedal1 {
            tempMin1 = Swift.min(tempMin1, rawValue)
            tempMax1 = Swift.max(tempMax1, rawValue)
            DispatchQueue.main.async {
                self.pedal1RangeLabel.stringValue = "Live: [\(self.tempMin1) - \(self.tempMax1)]"
            }
        } else if index == 1 && isCalibratingPedal2 {
            tempMin2 = Swift.min(tempMin2, rawValue)
            tempMax2 = Swift.max(tempMax2, rawValue)
            DispatchQueue.main.async {
                self.pedal2RangeLabel.stringValue = "Live: [\(self.tempMin2) - \(self.tempMax2)]"
            }
        }
        
        let pMin = (index == 0) ? pedal1Min : pedal2Min
        let pMax = (index == 0) ? pedal1Max : pedal2Max
        let pInvert = (index == 0) ? isPedal1Inverted : isPedal2Inverted
        
        if pMin == pMax {
            let baseVal = UInt8(round(Double(rawValue) * 127.0 / 255.0))
            return pInvert ? (127 - baseVal) : baseVal
        }
        
        let clamped = Swift.max(pMin, Swift.min(pMax, rawValue))
        let ratio = Double(clamped - pMin) / Double(pMax - pMin)
        
        if pInvert {
            return UInt8(round((1.0 - ratio) * 127.0))
        } else {
            return UInt8(round(ratio * 127.0))
        }
    }
    
    func driverDidUpdateStatus(_ status: String) {
        DispatchQueue.main.async {
            self.statusLabel.stringValue = "Status: \(status)"
            switch status {
            case "Connected":
                self.statusLabel.textColor = NSColor.systemGreen
            case "Scanning...":
                self.statusLabel.textColor = NSColor.systemBlue
            case "Connecting...", "Authenticating...":
                self.statusLabel.textColor = NSColor.systemOrange
            default:
                self.statusLabel.textColor = NSColor.systemRed
            }
        }
    }
    
    func driverDidUpdateBank(_ bank: UInt8) {
        DispatchQueue.main.async {
            let startPC = bank * 4
            let endPC = startPC + 3
            self.bankLabel.stringValue = "Current Bank: \(bank) (PC \(startPC) - \(endPC))"
        }
    }
    
    func driverDidUpdateActiveSwitch(_ index: UInt8?) {
        DispatchQueue.main.async {
            for i in 0..<4 {
                if let index = index, i == Int(index) {
                    self.switchIndicators[i].backgroundColor = NSColor.systemBlue
                } else {
                    self.switchIndicators[i].backgroundColor = NSColor.darkGray
                }
            }
        }
    }
    
    func driverDidUpdatePedal(index: UInt8, rawValue: UInt8, midiValue: UInt8) {
        DispatchQueue.main.async {
            let pct = Int(round(Double(midiValue) * 100.0 / 127.0))
            if index == 0 {
                self.pedal1Label.stringValue = "Pedal 1 (CC 7): \(pct)%"
                self.pedal1Indicator.doubleValue = Double(rawValue)
            } else {
                self.pedal2Label.stringValue = "Pedal 2 (CC 11): \(pct)%"
                self.pedal2Indicator.doubleValue = Double(rawValue)
            }
        }
    }
    
    func driverDidUpdateBattery(_ battery: UInt8) {
        DispatchQueue.main.async {
            if battery == 0 {
                self.batteryLabel.stringValue = "Battery: --%"
            } else {
                self.batteryLabel.stringValue = "Battery: \(battery)%"
            }
        }
    }
}

// MARK: - Main Entry Point
let app = NSApplication.shared
app.setActivationPolicy(.regular) // Makes it a standard windowed GUI application

let delegate = AppDelegate()
app.delegate = delegate
app.run()
