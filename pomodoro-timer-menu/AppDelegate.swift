import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var timeRemaining = 25 * 60 // 25 minuti
    var isRunning = false
    var completedPomodoros = 0
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusItem()
        setupMenu()
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusButton()
    }
    
    func setupMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "▶️ Avvia Timer", action: #selector(startTimer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⏸️ Pausa Timer", action: #selector(pauseTimer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "🔄 Reset Timer", action: #selector(resetTimer), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Pomodori: \(completedPomodoros)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "❌ Esci", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc func startTimer() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.tick()
        }
        updateStatusButton()
    }
    
    @objc func pauseTimer() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        updateStatusButton()
    }
    
    @objc func resetTimer() {
        pauseTimer()
        timeRemaining = 25 * 60
        updateStatusButton()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func tick() {
        timeRemaining -= 1
        
        if timeRemaining <= 0 {
            pauseTimer()
            completedPomodoros += 1
            timeRemaining = 25 * 60
            setupMenu() // Aggiorna il conteggio nel menu
            
            // Suono e alert
            NSSound.beep()
            showAlert()
        }
        
        updateStatusButton()
    }
    
    func updateStatusButton() {
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        let timeString = String(format: "%02d:%02d", minutes, seconds)
        let status = isRunning ? " " : ""
        
        // Crea testo con font più grande e grassetto
        let fullText = "🍅 \(timeString)\(status)"
        let attributedString = NSAttributedString(
            string: fullText,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 14), // Font grassetto e più grande
                .foregroundColor: NSColor.labelColor
            ]
        )
        
        statusItem.button?.attributedTitle = attributedString
    }
    
    func showAlert() {
        let alert = NSAlert()
        alert.messageText = "🍅 Pomodoro Completato!"
        alert.informativeText = "Hai completato un pomodoro (\(completedPomodoros) totali). Fai una pausa!"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
