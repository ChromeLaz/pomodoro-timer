import Cocoa
import IOKit
import IOKit.pwr_mgt
import AVFoundation

struct Task: Codable {
    var id = UUID()
    var name: String
    var completedPomodoros: Int = 0
    var isCompleted: Bool = false
    var savedTimeRemaining: Int = 25 * 60 // 25 MINUTI standard
    var isTimerActive: Bool = false // Track if this task has an active timer
}

enum TimerMode {
    case work        // 25 minuti - giallo
    case breakTime   // 5 minuti - verde
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var viewController: PomodoroViewController!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusItem()
        setupPopover()
        setupSleepNotifications()
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Initially show only tomato icon
            button.title = "🍅"
            button.font = NSFont.systemFont(ofSize: 16)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    func setupPopover() {
        popover = NSPopover()
        viewController = PomodoroViewController()
        popover.contentViewController = viewController
        popover.behavior = .transient
        
        viewController.onUpdateStatus = { [weak self] text in
            DispatchQueue.main.async {
                if let button = self?.statusItem.button {
                    button.title = text
                    button.font = NSFont.boldSystemFont(ofSize: 14)
                }
            }
        }
    }
    
    // MARK: - Sleep/Wake Notifications Setup
    func setupSleepNotifications() {
        // Register for sleep notifications
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        print("🛌 Sleep/Wake notifications registered")
    }
    
    @objc func handleSystemWillSleep() {
        print("🛌 System going to sleep - pausing timer")
        viewController.handleSystemSleep()
    }
    
    @objc func handleSystemDidWake() {
        print("⏰ System woke up - timer remains paused")
        viewController.handleSystemWake()
    }
    
    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}

class PomodoroViewController: NSViewController {
    var onUpdateStatus: ((String) -> Void)?
    
    // Timer logic
    var timer: Timer?
    var timeRemaining = 25 * 60  // 25 MINUTI standard
    var isRunning = false
    var currentTask: Task?
    var tasks: [Task] = []
    var selectedTaskIndex: Int?
    var timerMode: TimerMode = .work
    
    // Sleep/Wake tracking
    var wasRunningBeforeSleep = false
    var timeBeforeSleep: Date?
    
    // Audio player for powerful sound
    var audioPlayer: AVAudioPlayer?
    var soundTimer: Timer?
    
    // UI Elements
    var taskNameLabel: NSTextField!
    var timerLabel: NSTextField!
    var progressView: SimpleProgressView!
    var playPauseButton: NSButton!
    var resetButton: NSButton!
    var taskTableView: NSTableView!
    var scrollView: NSScrollView!
    var deleteButton: NSButton!
    var todayCounterLabel: NSTextField!
    var dailyPomodoroCount: Int = 0
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
        setupUI()
        setupAudioPlayer()
        loadTasks()
        updateDisplay()
        updateTaskList() // Force initial load of task list
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        if let layer = view.layer {
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
    
    // MARK: - Audio Setup
    func setupAudioPlayer() {
        // Usa il suono di sistema Glass che è più forte
        if let soundURL = Bundle.main.url(forResource: "Glass", withExtension: "aiff", subdirectory: "/System/Library/Sounds") {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
                audioPlayer?.prepareToPlay()
                audioPlayer?.volume = 1.0
            } catch {
                print("Errore nel caricare il suono: \(error)")
            }
        }
    }
    
    // MARK: - Sleep/Wake Handlers FIXED
    func handleSystemSleep() {
        if isRunning {
            wasRunningBeforeSleep = true
            timeBeforeSleep = Date()
            pauseTimer()
            print("⏸️ Timer paused due to system sleep at \(timeBeforeSleep!)")
        } else {
            wasRunningBeforeSleep = false
            timeBeforeSleep = nil
        }
    }
    
    func handleSystemWake() {
        if let sleepTime = timeBeforeSleep {
            let sleepDuration = Date().timeIntervalSince(sleepTime)
            print("⏰ System was asleep for \(sleepDuration) seconds")
            
            // Il timer rimane in pausa - l'utente deve riavviarlo manualmente
            print("⏰ Timer remains paused - user must restart manually")
        }
        
        wasRunningBeforeSleep = false
        timeBeforeSleep = nil
        updateDisplay()
    }
    
    func setupUI() {
        // Reset button (X) - top right
        resetButton = NSButton(frame: NSRect(x: 320, y: 460, width: 30, height: 30))
        resetButton.title = "✕"
        resetButton.font = NSFont.systemFont(ofSize: 16)
        resetButton.isBordered = false
        resetButton.target = self
        resetButton.action = #selector(resetTimer)
        view.addSubview(resetButton)
        
        // Task name centered - NO CHANGE BUTTON
        taskNameLabel = NSTextField(frame: NSRect(x: 40, y: 420, width: 280, height: 35))
        taskNameLabel.stringValue = "Select Task"
        taskNameLabel.font = NSFont.boldSystemFont(ofSize: 28)
        taskNameLabel.textColor = NSColor.labelColor
        taskNameLabel.alignment = .center
        taskNameLabel.isBezeled = false
        taskNameLabel.isEditable = false
        taskNameLabel.backgroundColor = NSColor.clear
        view.addSubview(taskNameLabel)
        
        // Timer Label
        timerLabel = NSTextField(frame: NSRect(x: 80, y: 330, width: 200, height: 80))
        timerLabel.stringValue = "25:00"  // 25 minuti standard
        timerLabel.font = NSFont.boldSystemFont(ofSize: 48)
        timerLabel.textColor = NSColor.systemOrange
        timerLabel.alignment = .center
        timerLabel.isBezeled = false
        timerLabel.isEditable = false
        timerLabel.backgroundColor = NSColor.clear
        view.addSubview(timerLabel)
        
        // Progress Bar
        progressView = SimpleProgressView(frame: NSRect(x: 30, y: 300, width: 300, height: 8))
        view.addSubview(progressView)
        
        // Play/Pause Button - BIGGER ICON
        playPauseButton = NSButton(frame: NSRect(x: 155, y: 245, width: 50, height: 50))
        playPauseButton.title = "▶"
        playPauseButton.font = NSFont.systemFont(ofSize: 32) // Bigger icon
        playPauseButton.isBordered = false
        playPauseButton.target = self
        playPauseButton.action = #selector(toggleTimer)
        view.addSubview(playPauseButton)
        
        // Task List Header
        let listLabel = NSTextField(frame: NSRect(x: 20, y: 210, width: 100, height: 20))
        listLabel.stringValue = "Tasks:"
        listLabel.font = NSFont.boldSystemFont(ofSize: 14)
        listLabel.isBezeled = false
        listLabel.isEditable = false
        listLabel.backgroundColor = NSColor.clear
        view.addSubview(listLabel)
        
        // Add Task Button
        let addTaskButton = NSButton(frame: NSRect(x: 300, y: 205, width: 40, height: 25))
        addTaskButton.title = "➕"
        addTaskButton.font = NSFont.systemFont(ofSize: 16)
        addTaskButton.isBordered = false
        addTaskButton.target = self
        addTaskButton.action = #selector(addNewTask)
        view.addSubview(addTaskButton)
        
        // Delete Button (initially hidden)
        deleteButton = NSButton(frame: NSRect(x: 250, y: 205, width: 40, height: 25))
        deleteButton.title = "🗑️"
        deleteButton.font = NSFont.systemFont(ofSize: 16)
        deleteButton.isBordered = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedTask)
        deleteButton.isHidden = true
        view.addSubview(deleteButton)
        
        // Task List
        scrollView = NSScrollView(frame: NSRect(x: 20, y: 50, width: 320, height: 150))
        taskTableView = NSTableView()
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TaskColumn"))
        column.title = "Tasks"
        column.width = 300
        taskTableView.addTableColumn(column)
        
        taskTableView.dataSource = self
        taskTableView.delegate = self
        taskTableView.headerView = nil
        taskTableView.rowHeight = 30
        taskTableView.target = self
        taskTableView.action = #selector(taskClicked)
        taskTableView.doubleAction = #selector(taskDoubleClicked)
        
        scrollView.documentView = taskTableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        view.addSubview(scrollView)
        
        // Today Counter - bottom left
        todayCounterLabel = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 20))
        todayCounterLabel.stringValue = "Today 🍅: 0"
        todayCounterLabel.font = NSFont.boldSystemFont(ofSize: 12)
        todayCounterLabel.textColor = NSColor.secondaryLabelColor
        todayCounterLabel.isBezeled = false
        todayCounterLabel.isEditable = false
        todayCounterLabel.backgroundColor = NSColor.clear
        view.addSubview(todayCounterLabel)
    }
    
    // MARK: - Key Events Handler
    override func keyDown(with event: NSEvent) {
        // Gestisci la pressione di Invio per rinominare il task selezionato
        if event.keyCode == 36 { // Codice per il tasto Invio
            if let selectedIndex = selectedTaskIndex {
                let sortedTasksList = sortedTasks()
                if selectedIndex < sortedTasksList.count {
                    let selectedTask = sortedTasksList[selectedIndex]
                    if !selectedTask.isCompleted {
                        renameTask(selectedTask)
                        return
                    }
                }
            }
        }
        super.keyDown(with: event)
    }
    
    // Assicuriamoci che la view possa ricevere eventi da tastiera
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        // Rendi la view il first responder per ricevere gli eventi da tastiera
        view.window?.makeFirstResponder(self)
    }
    
    @objc func toggleTimer() {
        if isRunning {
            pauseTimer()
        } else {
            startTimer()
        }
    }
    
    func startTimer() {
        guard !isRunning else { return }
        
        // Per i break non serve un task selezionato
        if timerMode == .work && currentTask == nil {
            showAlert(title: "No Task Selected", message: "Please select a task first!")
            return
        }
        
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.tick()
        }
        
        // Solo per modalità work, aggiorna il task
        if timerMode == .work {
            if let currentId = currentTask?.id,
               let index = tasks.firstIndex(where: { $0.id == currentId }) {
                tasks[index].isTimerActive = true
                currentTask = tasks[index]
                saveTasks()
            }
        }
        
        updateDisplay()
        updateTaskList()
        print("▶️ Timer started")
    }
    
    func pauseTimer() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        
        // Solo per modalità work, aggiorna il task
        if timerMode == .work {
            if let currentId = currentTask?.id,
               let index = tasks.firstIndex(where: { $0.id == currentId }) {
                tasks[index].isTimerActive = false
                currentTask = tasks[index]
                saveTasks()
            }
        }
        
        updateDisplay()
        updateTaskList()
        print("⏸️ Timer paused")
    }
    
    @objc func resetTimer() {
        pauseTimer()
        
        switch timerMode {
        case .work:
            timeRemaining = 25 * 60  // 25 MINUTI standard
            if let currentId = currentTask?.id,
               let index = tasks.firstIndex(where: { $0.id == currentId }) {
                tasks[index].savedTimeRemaining = 25 * 60  // 25 MINUTI
                tasks[index].isTimerActive = false
                currentTask = tasks[index]
                saveTasks()
            }
        case .breakTime:
            // Reset alla modalità work
            timerMode = .work
            timeRemaining = 25 * 60  // 25 MINUTI standard
        }
        
        updateDisplay()
        updateTaskList()
    }
    
    @objc func taskClicked() {
        let selectedRow = taskTableView.selectedRow
        selectedTaskIndex = selectedRow >= 0 ? selectedRow : nil
        
        // Show/hide delete button
        deleteButton.isHidden = selectedTaskIndex == nil
        
        // Assicurati che la view sia il first responder per ricevere eventi da tastiera
        view.window?.makeFirstResponder(self)
        
        // Change task when clicking on a different active task
        if let selectedIndex = selectedTaskIndex {
            let sortedTasksList = sortedTasks()
            if selectedIndex < sortedTasksList.count {
                let clickedTask = sortedTasksList[selectedIndex]
                
                // Only switch if it's a different active task and we're in work mode
                if !clickedTask.isCompleted && clickedTask.id != currentTask?.id && timerMode == .work {
                    // Save current task progress before switching
                    saveCurrentTaskProgress()
                    
                    // Load the new task's saved progress
                    currentTask = clickedTask
                    loadTaskProgress()
                    
                    updateTaskDisplay()
                    updateTaskList()
                    saveTasks()
                    
                    // Flash the selected task for 1 second
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.taskTableView.deselectAll(nil)
                        self.selectedTaskIndex = nil
                        self.deleteButton.isHidden = true
                        self.updateTaskList()
                    }
                }
            }
        }
        
        updateTaskList()
    }
    
    @objc func taskDoubleClicked() {
        // Double click now just renames the task
        let selectedRow = taskTableView.selectedRow
        guard selectedRow >= 0 && selectedRow < sortedTasks().count else { return }
        
        let task = sortedTasks()[selectedRow]
        if !task.isCompleted {
            renameTask(task)
        }
    }
    
    @objc func deleteSelectedTask() {
        guard let selectedIndex = selectedTaskIndex else { return }
        let sortedTasksList = sortedTasks()
        guard selectedIndex < sortedTasksList.count else { return }
        
        let taskToDelete = sortedTasksList[selectedIndex]
        
        // Create alert without showing modal that closes popover
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Delete Task"
            alert.informativeText = "Are you sure you want to delete '\(taskToDelete.name)'?"
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            
            // Run alert on a separate window to avoid closing popover
            if let window = self.view.window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn {
                        // Check if deleting current task while timer is running
                        let isDeletingCurrentTask = self.currentTask?.id == taskToDelete.id
                        
                        if isDeletingCurrentTask {
                            // Stop timer and reset if deleting current task
                            if self.isRunning {
                                self.pauseTimer()
                            }
                            self.timeRemaining = 25 * 60  // 25 MINUTI
                            self.timerMode = .work
                        }
                        
                        self.tasks.removeAll { $0.id == taskToDelete.id }
                        
                        if isDeletingCurrentTask {
                            // Auto-select next available task
                            let activeTasks = self.tasks.filter { !$0.isCompleted }
                            if !activeTasks.isEmpty {
                                self.currentTask = activeTasks[0]
                                self.loadTaskProgress()
                            } else {
                                self.currentTask = nil
                                self.timeRemaining = 25 * 60  // 25 MINUTI
                            }
                            self.updateTaskDisplay()
                            self.updateDisplay()
                        }
                        
                        self.selectedTaskIndex = nil
                        self.deleteButton.isHidden = true
                        self.updateTaskList()
                        self.saveTasks()
                    }
                }
            }
        }
    }
    
    @objc func addNewTask() {
        let alert = NSAlert()
        alert.messageText = "New Task"
        alert.informativeText = "Enter task name:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "e.g. Study Mathematics"
        alert.accessoryView = input
        
        // Run alert on a separate window to avoid closing popover
        if let window = self.view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn && !input.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Save current task progress before switching
                    self.saveCurrentTaskProgress()
                    
                    let newTask = Task(name: input.stringValue.trimmingCharacters(in: .whitespaces))
                    self.tasks.append(newTask)
                    
                    // Solo se siamo in modalità work, cambia task
                    if self.timerMode == .work {
                        self.currentTask = newTask
                        self.timeRemaining = 25 * 60  // 25 MINUTI standard
                    }
                    
                    self.updateTaskDisplay()
                    self.updateTaskList()
                    self.updateDisplay()
                    self.saveTasks()
                }
            }
        }
    }
    
    func renameTask(_ task: Task) {
        let alert = NSAlert()
        alert.messageText = "Rename Task"
        alert.informativeText = "Enter new name for the task:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = task.name
        alert.accessoryView = input
        
        if let window = self.view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn && !input.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let index = self.tasks.firstIndex(where: { $0.id == task.id }) {
                        self.tasks[index].name = input.stringValue.trimmingCharacters(in: .whitespaces)
                        
                        // Update current task if it's the one being renamed
                        if self.currentTask?.id == task.id {
                            self.currentTask = self.tasks[index]
                            self.updateTaskDisplay()
                        }
                        
                        self.updateTaskList()
                        self.saveTasks()
                    }
                }
            }
        }
    }
    
    func tick() {
        timeRemaining -= 1
        
        if timeRemaining <= 0 {
            pauseTimer()
            
            switch timerMode {
            case .work:
                // Pomodoro completato
                completePomodoro()
                
                // APRI SUBITO la pagina normale con messaggio "Pomodoro Completed"
                showPomodoroCompletedMessage()
                openMainPopover()
                
                // SUONERIA FORTE E CONTINUA per 3 secondi
                playPowerfulContinuousSound()
                
                // Avvia break dopo 3 secondi (quando finisce la suoneria)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.startBreakTimer()
                }
                
            case .breakTime:
                // Break completato
                // Suoneria come iPhone
                playiPhoneStyleSound()
                
                // NESSUN POPUP - torna a work mode e apri direttamente il popover
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.returnToWorkMode()
                    self.openMainPopover()
                }
            }
        }
        
        updateDisplay()
    }
    
    func completePomodoro() {
        if let currentId = currentTask?.id,
           let index = tasks.firstIndex(where: { $0.id == currentId }) {
            tasks[index].completedPomodoros += 1
            tasks[index].savedTimeRemaining = 25 * 60  // 25 MINUTI
            tasks[index].isTimerActive = false
            currentTask = tasks[index]
            
            // Increment daily counter
            dailyPomodoroCount += 1
            updateTodayCounter()
            
            updateTaskList()
            saveTasks()
        }
    }
    
    // MARK: - SUONERIA POTENTISSIMA E CONTINUA
    func playPowerfulContinuousSound() {
        // Ferma eventuali suoni precedenti
        soundTimer?.invalidate()
        
        // Imposta il volume del sistema al massimo temporaneamente
        
        var soundCount = 0
        let maxSounds = 30 // 30 suoni in 3 secondi = 10 al secondo
        
        // Timer che suona 10 volte al secondo per 3 secondi
        soundTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            soundCount += 1
            
            if soundCount > maxSounds {
                timer.invalidate()
                self.soundTimer = nil
                return
            }
            
            // Usa più suoni contemporaneamente per massima potenza
            DispatchQueue.global(qos: .userInteractive).async {
                // Suono 1: Glass (più forte)
                if let sound = NSSound(named: "Glass") {
                    sound.volume = 1.0
                    sound.play()
                }
                
                // Suono 2: Hero (aggiuntivo per più volume)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    if let sound = NSSound(named: "Hero") {
                        sound.volume = 1.0
                        sound.play()
                    }
                }
                
                // Suono 3: Sosumi (terzo livello)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    if let sound = NSSound(named: "Sosumi") {
                        sound.volume = 1.0
                        sound.play()
                    }
                }
            }
            
            // Vibrazione visiva del timer label per feedback
            DispatchQueue.main.async {
                let isEven = soundCount % 2 == 0
                self.timerLabel.textColor = isEven ? NSColor.systemRed : NSColor.systemOrange
                
                // Effetto pulsante
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.05
                    self.timerLabel.layer?.transform = isEven ?
                        CATransform3DMakeScale(1.1, 1.1, 1.0) :
                        CATransform3DMakeScale(1.0, 1.0, 1.0)
                }
            }
        }
        
        // Assicurati che il timer si fermi dopo 3 secondi
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.soundTimer?.invalidate()
            self.soundTimer = nil
            self.timerLabel.textColor = NSColor.systemOrange
            self.timerLabel.layer?.transform = CATransform3DIdentity
        }
    }
    
    // Variabile temporanea per mostrare il messaggio di completamento
    var isPomodoroCompleted = false
    
    func showPomodoroCompletedMessage() {
        isPomodoroCompleted = true
        updateTaskDisplay() // Aggiorna il display per mostrare il messaggio
        
        // Nascondi il messaggio dopo 3 secondi (durata della suoneria)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.isPomodoroCompleted = false
            self.updateTaskDisplay() // Ripristina il display normale
        }
    }
    
    func openMainPopover() {
        // Apri il popover principale dell'app
        if let appDelegate = NSApp.delegate as? AppDelegate {
            if let button = appDelegate.statusItem.button {
                if !appDelegate.popover.isShown {
                    appDelegate.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
        }
    }
    
    func playiPhoneStyleSound() {
        // Suoneria POTENTE - BIP BIP BIP per 2-3 secondi!
        let soundTimes = [0.0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8, 2.1, 2.4]
        
        for delay in soundTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Usa il suono di sistema più forte
                if let sound = NSSound(named: "Glass") {
                    sound.volume = 1.0 // Volume massimo
                    sound.play()
                } else {
                    NSSound.beep() // Fallback
                }
            }
        }
    }
    
    func startBreakTimer() {
        timerMode = .breakTime
        timeRemaining = 5 * 60  // 5 MINUTI standard per break
        updateDisplay()  // IMPORTANTE: aggiorna display per nascondere X
        updateTaskDisplay()
        startTimer() // Avvia automaticamente
    }
    
    func returnToWorkMode() {
        timerMode = .work
        timeRemaining = 25 * 60  // 25 MINUTI standard
        updateDisplay()  // IMPORTANTE: aggiorna display per mostrare X di nuovo
        updateTaskDisplay()
        // Non avviare automaticamente il timer work
    }
    
    func updateDisplay() {
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        let timeString = String(format: "%02d:%02d", minutes, seconds)
        
        timerLabel.stringValue = timeString
        
        // Colore del timer basato sulla modalità - VERDE SEMPRE DURANTE BREAK
        switch timerMode {
        case .work:
            timerLabel.textColor = NSColor.systemOrange
        case .breakTime:
            timerLabel.textColor = NSColor.systemGreen  // SEMPRE VERDE!
        }
        
        // Update play/pause button
        playPauseButton.title = isRunning ? "⏸" : "▶"
        
        // NASCONDI COMPLETAMENTE il pulsante Reset (X) durante BREAK TIME
        if timerMode == .breakTime {
            resetButton.isHidden = true
        } else {
            resetButton.isHidden = false
        }
        
        // Update progress bar
        let totalTime: Float
        switch timerMode {
        case .work:
            totalTime = Float(25 * 60)  // 25 MINUTI
        case .breakTime:
            totalTime = Float(5 * 60)  // 5 MINUTI per break
        }
        
        let elapsed = Float(totalTime - Float(timeRemaining))
        progressView.progress = elapsed / totalTime
        progressView.isActive = isRunning
        progressView.timerMode = timerMode
        
        // Update status bar
        let emoji = timerMode == .work ? "🍅" : "☕"
        onUpdateStatus?("\(timeString) \(emoji)")
    }
    
    func updateTaskDisplay() {
        if isPomodoroCompleted {
            // Mostra messaggio di completamento durante la suoneria
            taskNameLabel.stringValue = "🍅 Pomodoro Completed!\nTake a Pause"
        } else if timerMode == .breakTime {
            taskNameLabel.stringValue = "☕ Break Time"
        } else if let current = currentTask {
            taskNameLabel.stringValue = current.name
        } else {
            taskNameLabel.stringValue = "Select Task"
        }
    }
    
    func updateTaskList() {
        taskTableView.reloadData()
        // Don't auto-select current task, only show selection when manually clicking
    }
    
    func updateTodayCounter() {
        todayCounterLabel.stringValue = "Today 🍅: \(dailyPomodoroCount)"
    }
    
    // MARK: - Task Progress Management
    
    func saveCurrentTaskProgress() {
        guard timerMode == .work else { return } // Solo per work mode
        
        guard let currentId = currentTask?.id,
              let index = tasks.firstIndex(where: { $0.id == currentId }) else { return }
        
        // Save current progress and timer state
        tasks[index].savedTimeRemaining = timeRemaining
        tasks[index].isTimerActive = isRunning
        
        // Pause timer when switching tasks
        pauseTimer()
    }
    
    func loadTaskProgress() {
        guard timerMode == .work else { return } // Solo per work mode
        
        guard let current = currentTask else {
            timeRemaining = 25 * 60  // 25 MINUTI standard
            return
        }
        
        // Load saved progress for this task
        timeRemaining = current.savedTimeRemaining
        
        // CRITICAL: Update the currentTask reference with fresh data from array
        if let index = tasks.firstIndex(where: { $0.id == current.id }) {
            currentTask = tasks[index]
        }
        
        updateDisplay()
    }
    
    // Sort tasks: current task first, then active tasks, then completed tasks
    func sortedTasks() -> [Task] {
        var result: [Task] = []
        
        // 1. Current task first (if exists and not completed and in work mode)
        if let current = currentTask, !current.isCompleted && timerMode == .work {
            result.append(current)
        }
        
        // 2. Other active tasks (excluding current)
        let otherActiveTasks = tasks.filter { !$0.isCompleted && $0.id != currentTask?.id }.sorted { $0.name < $1.name }
        result.append(contentsOf: otherActiveTasks)
        
        // 3. Completed tasks last
        let completedTasks = tasks.filter { $0.isCompleted }.sorted { $0.name < $1.name }
        result.append(contentsOf: completedTasks)
        
        return result
    }
    
    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    func markTaskCompleted() {
        if let currentId = currentTask?.id,
           let index = tasks.firstIndex(where: { $0.id == currentId }) {
            tasks[index].isCompleted = true
            currentTask = nil
            updateTaskDisplay()
            updateTaskList()
            saveTasks()
            
            let alert = NSAlert()
            alert.messageText = "✅ Task Completed!"
            alert.informativeText = "Congratulations! You completed the task."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    // MARK: - Daily Counter Management (FIXED)
    
    func getTodayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
    
    func loadDailyCounter() {
        let today = getTodayDateString()
        let lastDate = UserDefaults.standard.string(forKey: "LastPomodoroDate")
        
        print("🔍 DEBUG: Today: \(today), Last saved date: \(lastDate ?? "nil")")
        
        if lastDate == today {
            // Stesso giorno - carica il contatore salvato
            dailyPomodoroCount = UserDefaults.standard.integer(forKey: "DailyPomodoroCount")
            print("✅ Same day - loaded counter: \(dailyPomodoroCount)")
        } else {
            // Nuovo giorno - RESET contatore a 0
            print("🔄 NEW DAY DETECTED - resetting counter from \(UserDefaults.standard.integer(forKey: "DailyPomodoroCount")) to 0")
            dailyPomodoroCount = 0
            UserDefaults.standard.set(0, forKey: "DailyPomodoroCount")
            UserDefaults.standard.set(today, forKey: "LastPomodoroDate")
        }
    }
    
    func saveDailyCounter() {
        let today = getTodayDateString()
        UserDefaults.standard.set(dailyPomodoroCount, forKey: "DailyPomodoroCount")
        UserDefaults.standard.set(today, forKey: "LastPomodoroDate")
        print("💾 Saved daily counter: \(dailyPomodoroCount) for date: \(today)")
    }
    
    func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: "PomodoroTasks"),
           let decoded = try? JSONDecoder().decode([Task].self, from: data) {
            tasks = decoded
        }
        
        if let currentIdString = UserDefaults.standard.string(forKey: "CurrentTaskId"),
           let currentId = UUID(uuidString: currentIdString),
           let task = tasks.first(where: { $0.id == currentId && !$0.isCompleted }) {
            currentTask = task
        }
        
        // FIXED: Load daily counter with proper date checking
        loadDailyCounter()
        
        if tasks.isEmpty {
            tasks = [
                Task(name: "Study", completedPomodoros: 0),
                Task(name: "Reading", completedPomodoros: 0),
                Task(name: "Project Work", completedPomodoros: 0)
            ]
            saveTasks()
        }
        
        // Auto-select first active task if no current task
        if currentTask == nil {
            let activeTasks = tasks.filter { !$0.isCompleted }
            if !activeTasks.isEmpty {
                currentTask = activeTasks[0]
                saveTasks()
            }
        }
        
        // Load progress for current task if exists
        if currentTask != nil {
            loadTaskProgress()
        }
        
        updateTaskDisplay()
        updateTodayCounter()
    }
    
    func saveTasks() {
        if let encoded = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(encoded, forKey: "PomodoroTasks")
        }
        
        if let currentId = currentTask?.id {
            UserDefaults.standard.set(currentId.uuidString, forKey: "CurrentTaskId")
        } else {
            UserDefaults.standard.removeObject(forKey: "CurrentTaskId")
        }
        
        // FIXED: Save daily counter with proper date
        saveDailyCounter()
    }
}

// MARK: - TableView DataSource & Delegate
extension PomodoroViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return sortedTasks().count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let sortedTasksList = sortedTasks()
        let task = sortedTasksList[row]
        let cellView = TaskCellView()
        
        cellView.setupCell(
            task: task,
            isSelected: selectedTaskIndex == row,
            onToggle: { [weak self] in
                self?.toggleTaskCompletion(task)
            }
        )
        
        return cellView
    }
    
    func toggleTaskCompletion(_ task: Task) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            let wasCompleted = tasks[index].isCompleted
            tasks[index].isCompleted.toggle()
            
            // If this was the current task and now completed, clear current task
            if currentTask?.id == task.id && tasks[index].isCompleted {
                currentTask = nil
                updateTaskDisplay()
                
                // Auto-select next available task
                let activeTasks = tasks.filter { !$0.isCompleted }
                if !activeTasks.isEmpty {
                    currentTask = activeTasks[0]
                    loadTaskProgress()
                    updateTaskDisplay()
                } else {
                    currentTask = nil
                    updateTaskDisplay()
                }
            }
            
            // Only animate position change when marking as completed (not when uncompleting)
            if !wasCompleted && tasks[index].isCompleted {
                // Task was just completed - animate move to bottom with delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.5
                        context.allowsImplicitAnimation = true
                        self.updateTaskList()
                    }
                }
            } else {
                // Task was uncompleted or other change - update immediately without animation
                updateTaskList()
            }
            
            saveTasks()
        }
    }
}

// MARK: - Custom Task Cell View
class TaskCellView: NSTableCellView {
    var toggleButton: NSButton!
    var taskLabel: NSTextField!
    var onToggle: (() -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    func setupUI() {
        // Toggle Button (Circle)
        toggleButton = NSButton(frame: NSRect(x: 8, y: 5, width: 20, height: 20))
        toggleButton.setButtonType(.momentaryPushIn)
        toggleButton.isBordered = false
        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        addSubview(toggleButton)
        
        // Task Label
        taskLabel = NSTextField(frame: NSRect(x: 35, y: 5, width: 250, height: 20))
        taskLabel.isBezeled = false
        taskLabel.isEditable = false
        taskLabel.backgroundColor = NSColor.clear
        taskLabel.font = NSFont.systemFont(ofSize: 12)
        addSubview(taskLabel)
    }
    
    func setupCell(task: Task, isSelected: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        
        // Setup toggle button - USE GRAY CHECK MARK
        toggleButton.title = task.isCompleted ? "✓" : "○"
        toggleButton.font = NSFont.boldSystemFont(ofSize: 16)
        toggleButton.contentTintColor = task.isCompleted ? NSColor.systemGray : NSColor.systemGray
        
        // Setup label - NO EMOJIS when completed to avoid bugs
        if task.isCompleted {
            let taskText = "\(task.name) - \(task.completedPomodoros)"
            let attributedString = NSMutableAttributedString(string: taskText)
            attributedString.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: taskText.count))
            attributedString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: taskText.count))
            taskLabel.attributedStringValue = attributedString
        } else {
            // Only show emojis for active tasks
            let baseText = "\(task.name) - \(task.completedPomodoros)"
            // Show hourglass ONLY if: has progress AND is paused (not active) AND has saved time < 25min
            let showHourglass = task.savedTimeRemaining < (25 * 60) && !task.isTimerActive
            let progressIndicator = showHourglass ? " ⏳" : ""
            let taskText = "\(baseText)🍅\(progressIndicator)"
            taskLabel.stringValue = taskText
            taskLabel.textColor = NSColor.labelColor
        }
        
        // Background for selected task - ONLY GRAY
        wantsLayer = true
        layer?.backgroundColor = isSelected ? NSColor.darkGray.cgColor : NSColor.clear.cgColor
        layer?.cornerRadius = 4
    }
    
    @objc func toggleClicked() {
        onToggle?()
    }
}

// MARK: - Simple Progress View
class SimpleProgressView: NSView {
    var progress: Float = 0.0 {
        didSet {
            needsDisplay = true
        }
    }
    
    var isActive: Bool = false {
        didSet {
            needsDisplay = true
        }
    }
    
    var timerMode: TimerMode = .work {
        didSet {
            needsDisplay = true
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Background
        NSColor.quaternaryLabelColor.setFill()
        let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        backgroundPath.fill()
        
        // Progress
        if progress > 0 {
            let progressWidth = CGFloat(progress) * bounds.width
            let progressRect = NSRect(x: 0, y: 0, width: progressWidth, height: bounds.height)
            
            let color: NSColor
            if isActive {
                color = timerMode == .work ? NSColor.systemOrange : NSColor.systemGreen
            } else {
                color = NSColor.systemGray
            }
            
            color.setFill()
            let progressPath = NSBezierPath(roundedRect: progressRect, xRadius: 4, yRadius: 4)
            progressPath.fill()
        }
    }
}
