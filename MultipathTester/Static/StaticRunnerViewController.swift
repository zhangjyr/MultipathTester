//
//  StaticRunnerViewController.swift
//  QUICTester
//
//  Created by Quentin De Coninck on 1/9/18.
//  Copyright © 2018 Universite Catholique de Louvain. All rights reserved.
//

import CoreLocation
import UIKit
import Quictraffic
import Charts

class StaticRunnerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    var currentResultViewController: UIViewController?
    @IBOutlet weak var resultContainerView: UIView!
    @IBOutlet weak var testsTable: UITableView!
    @IBOutlet weak var progress: UICircularProgressRingView!
    
    var startTime: Date = Date()
    var stopTime: Date = Date()
    
    var pingTests = [TCPConnectivityTest]()
    var quicPingTests = [QUICConnectivityTest]()
    var quicV4Connectivity = QUICConnectivityTest(ipVer: .v4, port: 443)
    var quicV6Connectivity = QUICConnectivityTest(ipVer: .v6, port: 443)
    var quic6121Connectivity = QUICConnectivityTest(ipVer: .any, port: 6121)
    var quicV4Tests = [Test]()
    var quicV6Tests = [Test]()
    var mpquicTests = [Test]()
    var mptcpTests = [Test]()
    var tests: [Test] = [Test]()
    var allTests: [Test] = [Test]()
    var runningIndex: Int = -1
    var stoppedIndex: Int = -1
    var testsDone: Int = 0
    var userInterrupted: Bool = false
    var finalizing: Bool = false
    
    var internetReachability: Reachability = Reachability.forInternetConnection()
    var locationTracker: LocationTracker = LocationTracker.sharedTracker()
    var locations: [Location] = []
    var connectivities = [Connectivity]()
    
    // Reachability does not warn about the cellular state if WiFi is on...
    var wasCellularOn: Bool = false
    var cellTimer: Timer?
    var stoppedTests: Bool = false
    
    var chartTimer: Timer?
    
    // Value come from StaticMainViewController
    var aggregate: Bool = false
    
    // Detect app going to background
    var backgrounded = false
    
    var multipathService: RunConfig.MultipathServiceType = .aggregate
    
    //var debugCount = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        _ = locationTracker.startIfAuthorized()
        self.progress.value = 0.0
        
        pingTests = [
            // Zero ping count because pingOne after
            TCPConnectivityTest(ipVer: .any, port: 443, testServer: .fr, pingCount: 0, pingWaitMs: 200),
            TCPConnectivityTest(ipVer: .any, port: 443, testServer: .ca, pingCount: 0, pingWaitMs: 200),
            TCPConnectivityTest(ipVer: .any, port: 443, testServer: .jp, pingCount: 0, pingWaitMs: 200),
        ]
        
        // This randomize the order of the pings, to avoid correlating traffic too much
        pingTests.shuffle()
        
        quicPingTests = [
            quic6121Connectivity,
            quicV4Connectivity,
            quicV6Connectivity,
        ]
        
        quicPingTests.shuffle()
        
        quicV4Tests = [
            QUICBulkDownloadTest(ipVer: .v4, urlPath: "/10MB", maxPathID: 0),
            QUICStreamTest(ipVer: .v4, maxPathID: 0, runTime: 7),
            QUICPerfTest(ipVer: .v4, maxPathID: 0),
        ]
        
        quicV6Tests = [
            QUICBulkDownloadTest(ipVer: .v6, urlPath: "/10MB", maxPathID: 0),
            QUICStreamTest(ipVer: .v6, maxPathID: 0, runTime: 7),
            QUICPerfTest(ipVer: .v6, maxPathID: 0),
        ]
        
        mpquicTests = [
            QUICBulkDownloadTest(ipVer: .any, urlPath: "/10MB", maxPathID: 255),
            QUICStreamTest(ipVer: .any, maxPathID: 255, runTime: 7),
            QUICPerfTest(ipVer: .any, maxPathID: 255),
        ]
        
        // Do not allow MPTCP tests if aggregate mode is on
        if !aggregate {
            mptcpTests = [
                TCPBulkDownloadTest(ipVer: .any, urlPath: "/10MB", multipath: true),
                TCPStreamTest(ipVer: .any, runTime: 7, multipath: true),
                TCPPerfTest(ipVer: .any, multipath: true),
            ]
        }
        
        // Tests will be filled up during the tests
        tests = (pingTests as [Test]) + (quicPingTests as [Test])

        allTests = (pingTests as [Test]) + (quicPingTests as [Test])
        allTests += quicV4Tests
        allTests += quicV6Tests
        allTests += mpquicTests
        allTests += mptcpTests
        
        multipathService = .handover
        if aggregate {
            multipathService = .aggregate
        }
        for t in allTests {
            t.setMultipathService(service: multipathService)
        }
        
        locations = []
        
        // Start observing app going to background notifications
        NotificationCenter.default.addObserver(self, selector: #selector(MobileRunnerViewController.applicationDidSwitchToBackground(note:)), name: UIApplication.didEnterBackgroundNotification, object: nil)

        
        NotificationCenter.default.post(name: Utils.TestsLaunchedNotification, object: nil, userInfo: ["startNewTestsEnabled": false])
        
        NotificationCenter.default.addObserver(self, selector: #selector(StaticRunnerViewController.reachabilityChanged(note:)), name: .reachabilityChanged, object: nil)
        internetReachability.startNotifier()
        
        NotificationCenter.default.addObserver(self, selector: #selector(StaticRunnerViewController.locationChanged(note:)), name: LocationTracker.LocationTrackerNotification, object: nil)
        
        locationTracker.forceUpdate()
        
        testsTable.dataSource = self
        testsTable.delegate = self
        
        // Show the result label view, not the chart one
        self.currentResultViewController = self.storyboard?.instantiateViewController(withIdentifier: "resultLabelViewController")
        self.currentResultViewController!.view.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(currentResultViewController!.view, toView: resultContainerView)
        
        startTests()
    }
    
    func addSubview(_ subView:UIView, toView parentView:UIView) {
        parentView.addSubview(subView)
        
        var viewBindingsDict = [String: AnyObject]()
        viewBindingsDict["subView"] = subView
        parentView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "H:|[subView]|",
                                                                                 options: [], metrics: nil, views: viewBindingsDict))
        parentView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[subView]|",
                                                                                 options: [], metrics: nil, views: viewBindingsDict))
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    func stopTests() {
        self.stoppedTests = true
        self.stoppedIndex = self.runningIndex
        if backgrounded {
            let alert = UIAlertController(title: "Test interrupted!", message: "The tests stopped because the application backgrounded.", preferredStyle: UIAlertController.Style.alert)
            alert.addAction(UIAlertAction(title: "OK", style: UIAlertAction.Style.default, handler: nil))
            self.present(alert, animated: true, completion: nil)
        } else {
            let alert = UIAlertController(title: "Test interrupted!", message: "The tests stopped because network conditions changed. If you want to evaluate mobile cases, please try mobile tests.", preferredStyle: UIAlertController.Style.alert)
            alert.addAction(UIAlertAction(title: "OK", style: UIAlertAction.Style.default, handler: nil))
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    // MARK: App state tracking
    @objc
    func applicationDidSwitchToBackground(note: Notification) {
        backgrounded = true
        stopTests()
    }
    
    func networkTypeChanged(conn: Connectivity) -> Bool {
        let networkType = conn.networkType
        let lastNetworkType = connectivities.last!.networkType
        // WifiCellular and CellularWifi are still considered the same now...
        if (lastNetworkType == .WiFiCellular || lastNetworkType == .CellularWifi) && (networkType == .WiFiCellular || networkType == .CellularWifi) {
            // Log the new connectivity in connectivities
            connectivities.append(conn)
            return false
        }
        return networkType != lastNetworkType
    }
    
    @objc
    func reachabilityChanged(note: Notification) {
        let reachabilityStatus = internetReachability.currentReachabilityStatus()
        let conn = Connectivity.getCurrentConnectivity(reachabilityStatus: reachabilityStatus)
        if networkTypeChanged(conn: conn) || (conn.wifiBSSID != nil && conn.wifiBSSID != connectivities[0].wifiBSSID) {
            connectivities.append(conn)
            print("Reachability changed!")
            for i in 0..<tests.count {
                QuictrafficNotifyReachability(tests[i].getNotifyID())
            }
            stopTests()
        }
        
    }
    
    @objc
    func locationChanged(note: Notification) {
        let info = note.userInfo
        guard let locations = info!["locations"] as? [CLLocation] else {
            return
        }
        for cl in locations {
            let location = Location(lon: cl.coordinate.longitude, lat: cl.coordinate.latitude, timestamp: cl.timestamp, accuracy: cl.horizontalAccuracy, altitude: cl.altitude, speed: cl.speed)
            self.locations.append(location)
        }
    }
    
    func performPings() -> (TestServer, Double, Double) {
        let nbTests = self.allTests.count
        var bestServer: TestServer = .fr
        var bestMed: Double = Double.greatestFiniteMagnitude
        var bestStd: Double = Double.greatestFiniteMagnitude
        
        let queue = OperationQueue()
        let group = DispatchGroup()
        
        for i in 0..<self.pingTests.count {
            let test = self.pingTests[i]
            group.enter()
            queue.addOperation {
                test.run()
                group.leave()
            }
        }
        DispatchQueue.main.async {
            self.progress.setProgress(value: CGFloat(0.0), animationDuration: 0.0) {}
            self.testsTable.reloadData()
            self.progress.setProgress(value: CGFloat((Float(self.pingTests.count) / Float(nbTests) * 100.0 / 6)), animationDuration: 1.0) {}
        }
        group.wait()
        
        let pingCount = 5
        for pc in 0..<pingCount {
            DispatchQueue.main.async {
                self.testsTable.reloadData()
                let fixPart: CGFloat = CGFloat(Float(self.pingTests.count) / Float(nbTests) * 100.0) / 6
                let mobilePart: CGFloat = CGFloat(Float(pc) + 1.0)
                self.progress.setProgress(value: fixPart * mobilePart, animationDuration: 1.0) {}
            }
            for i in 0..<self.pingTests.count {
                let test = self.pingTests[i]
                if test.succeeded() {
                    group.enter()
                    queue.addOperation {
                        test.runOnePing()
                        group.leave()
                    }
                }
            }
            group.wait()
            // Wait for 100 ms before next burst
            usleep(100 * 1000)
        }
        for i in 0..<self.pingTests.count {
            let test = self.pingTests[i]
            // Close file descriptors
            test.finish()
            let durations = test.durations
            if test.succeeded() && durations.count == pingCount {
                let median = durations.median()
                print("median duration of", test.getTestServer(), "is", median)
                if median >= 0.0 && median < bestMed {
                    bestServer = test.getTestServer()
                    bestMed = median
                    bestStd = durations.standardDeviation()
                }
            }
        }
        
        return (bestServer, bestMed, bestStd)
    }
    
    func performQUICPings() {
        let nbTests = self.allTests.count
        for i in 0..<self.quicPingTests.count {
            let test = self.quicPingTests[i]
            DispatchQueue.main.async {
                self.progress.setProgress(value: CGFloat((Float(i + self.pingTests.count) / Float(nbTests) * 100.0)), animationDuration: 0.0) {}
                self.runningIndex = i + self.pingTests.count
                self.testsTable.reloadData()
                let waitTime = test.getWaitTime()
                let runTime = test.getRunTime()
                let increment = waitTime / (waitTime + runTime)
                let percentage = (Float(i) + Float(self.pingTests.count) + Float(increment)) / Float(nbTests) * 100.0
                self.progress.setProgress(value: CGFloat(percentage), animationDuration: waitTime) {
                    // Do anything your heart desires...
                    print("wait completed")
                    self.progress.setProgress(value: CGFloat((Float(i + 1 + self.pingTests.count) / Float(nbTests) * 100.0) - 1.0), animationDuration: runTime) {print("test completed")}
                }
            }
            if self.stoppedTests || self.userInterrupted {
                break
            }
            test.run()
            testsDone += 1
            // Wait AFTER the test; take the case of iPerf just before ping...
            test.wait()
            if self.stoppedTests || self.userInterrupted {
                break
            }
        }
    }
    
    func cycleFromViewController(_ oldViewController: UIViewController, toViewController newViewController: UIViewController) {
        oldViewController.willMove(toParent: nil)
        self.addChild(newViewController)
        self.addSubview(newViewController.view, toView:self.resultContainerView!)
        newViewController.view.alpha = 0
        newViewController.view.layoutIfNeeded()
        UIView.animate(withDuration: 0.1, animations: {
            newViewController.view.alpha = 1
            oldViewController.view.alpha = 0
        },
                                   completion: { finished in
                                    oldViewController.view.removeFromSuperview()
                                    oldViewController.removeFromParent()
                                    newViewController.didMove(toParent: self)
        })
    }
    
    func startTests() {
        finalizing = false
        UIApplication.shared.isIdleTimerDisabled = true
        connectivities = [Connectivity]()
        let reachabilityStatus = internetReachability.currentReachabilityStatus()
        wasCellularOn = UIDevice.current.hasCellularConnectivity
        connectivities.append(Connectivity.getCurrentConnectivity(reachabilityStatus: reachabilityStatus))
        let wifiInfoStart = InterfaceInfo.getInterfaceInfo(netInterface: .WiFi)
        let cellInfoStart = InterfaceInfo.getInterfaceInfo(netInterface: .Cellular)
        startTime = Date()
        self.navigationItem.hidesBackButton = true
        cellTimer = Timer(timeInterval: 0.5, target: self, selector: #selector(StaticRunnerViewController.probeCellular), userInfo: nil, repeats: true)
        RunLoop.current.add(cellTimer!, forMode: RunLoop.Mode.common)
        chartTimer = Timer(timeInterval: 0.2, target: self, selector: #selector(StaticRunnerViewController.updateChart), userInfo: nil, repeats: true)
        RunLoop.current.add(chartTimer!, forMode: RunLoop.Mode.common)
        print("Chart timer set")
        print("We start the tests")
        let resultLabelViewController = self.currentResultViewController as! ResultLabelViewController
        resultLabelViewController.label.text = "Searching for the nearest server..."
        
        DispatchQueue.global(qos: .userInteractive).async {
            self.testsDone = 0
            
            // -- Phase 1 : TCP Pings to determine the test server
            let (bestServer, bestMed, bestStd) = self.performPings()
            print("Best server is", bestServer)
            DispatchQueue.main.async {
                resultLabelViewController.label.text = "Selected server \(bestServer)"
            }
            for i in self.pingTests.count..<self.tests.count {
                let test = self.tests[i]
                test.setTestServer(testServer: bestServer)
            }
            self.testsDone += self.pingTests.count
            
            // -- Phase 2 : QUIC Pings to determine which tests should be done
            self.performQUICPings()
            
            // -- Phase 3 : Determine which tests will be performed
            var addedTests = [Test]()
            if self.quicV4Connectivity.succeeded() {
                addedTests += self.quicV4Tests
            }
            if self.quicV6Connectivity.succeeded() {
                addedTests += self.quicV6Tests
            }
            
            // If no QUIC test succeeded, there is no point in trying Multipath QUIC traffic...
            if self.quicV4Connectivity.succeeded() || self.quicV6Connectivity.succeeded() || self.quic6121Connectivity.succeeded() {
                addedTests += self.mpquicTests
            }
            
            // Shuffle QUIC tests
            addedTests.shuffle()
            
            // XXX MPTCP tests crashes on 11.2.6 when using only one interface...
            let os = ProcessInfo().operatingSystemVersion
            if (self.connectivities[0].networkType == .WiFiCellular || self.connectivities[0].networkType == .CellularWifi) || (os.majorVersion >= 11 && os.minorVersion >= 3) {
                self.mptcpTests.shuffle()
                addedTests += self.mptcpTests // Also add MPTCP tests
            }
            
            // No more shuffle, put MPTCP tests at the end
            
            // Don't forget to provide the right test server to added tests
            for i in 0..<addedTests.count {
                let test = addedTests[i]
                test.setTestServer(testServer: bestServer)
            }
            
            // Now add them
            self.tests += addedTests
            let nbTests = self.tests.count
            
            let groupResult = DispatchGroup()
            groupResult.enter()
            // We are nearly done, we will just now show chart view...
            DispatchQueue.main.async {
                let newViewController = self.storyboard?.instantiateViewController(withIdentifier: "resultLineChartViewController")
                newViewController!.view.translatesAutoresizingMaskIntoConstraints = false
                self.cycleFromViewController(self.currentResultViewController!, toViewController: newViewController!)
                self.currentResultViewController = newViewController
                groupResult.leave()
            }
            groupResult.wait()
            
            // -- Phase 4 : run additional tests
            for i in (self.pingTests.count + self.quicPingTests.count)..<self.tests.count {
                let test = self.tests[i]
                DispatchQueue.main.async {
                    self.progress.setProgress(value: CGFloat((Float(i) / Float(nbTests) * 100.0)), animationDuration: 0.0) {}
                    self.runningIndex = i
                    self.testsTable.reloadData()
                    let waitTime = test.getWaitTime()
                    let runTime = test.getRunTime()
                    let increment = waitTime / (waitTime + runTime)
                    let percentage = (Float(i) + Float(increment)) / Float(nbTests) * 100.0
                    self.progress.setProgress(value: CGFloat(percentage), animationDuration: waitTime) {
                        // Do anything your heart desires...
                        print("wait completed")
                        self.progress.setProgress(value: CGFloat((Float(i + 1) / Float(nbTests) * 100.0) - 1.0), animationDuration: runTime) {print("test completed")}
                    }
                }
                if self.stoppedTests || self.userInterrupted {
                    break
                }
                test.run()
                self.testsDone += 1
                // Wait AFTER the test; take the case of iPerf just before ping...
                test.wait()
                if self.stoppedTests || self.userInterrupted {
                    break
                }
            }
            self.stopTime = Date()
            self.finalizing = true
            let wifiInfoEnd = InterfaceInfo.getInterfaceInfo(netInterface: .WiFi)
            let cellInfoEnd = InterfaceInfo.getInterfaceInfo(netInterface: .Cellular)
            let wifiBytesSent = wifiInfoEnd.bytesSent - wifiInfoStart.bytesSent
            let wifiBytesReceived = wifiInfoEnd.bytesReceived - wifiInfoStart.bytesReceived
            let cellBytesSent = cellInfoEnd.bytesSent - cellInfoStart.bytesSent
            let cellBytesReceived = cellInfoEnd.bytesReceived - cellInfoStart.bytesReceived
            self.runningIndex = self.testsDone
            // We're close of the end, so let the user be aware of this
            DispatchQueue.main.async {
                let newViewController = self.storyboard?.instantiateViewController(withIdentifier: "resultLabelViewController")
                newViewController!.view.translatesAutoresizingMaskIntoConstraints = false
                self.cycleFromViewController(self.currentResultViewController!, toViewController: newViewController!)
                self.currentResultViewController = newViewController
                let resultLabelViewController = self.currentResultViewController as! ResultLabelViewController
                resultLabelViewController.label.text = "Finalizing the test, this should take a few seconds..."
            }
            var testResults = [TestResult]()
            for i in 0..<self.testsDone {
                let test = self.tests[i]
                let result = test.getTestResult()
                if self.stoppedTests && self.backgrounded && i == self.testsDone - 1 {
                    result.setAbortedBackgrounded()
                }
                else if self.stoppedTests && i == self.testsDone - 1 {
                    result.setFailedByNetworkChange()
                }
                testResults.append(result)
            }
            DispatchQueue.main.async {
                self.testsTable.reloadData()
            }
            let duration = self.stopTime.timeIntervalSince(self.startTime)
            
            let benchmark = Benchmark(connectivities: self.connectivities, duration: duration, locations: self.locations, mobile: false, pingMed: bestMed, pingStd: bestStd, wifiBytesReceived: wifiBytesReceived, wifiBytesSent: wifiBytesSent, cellBytesReceived: cellBytesReceived, cellBytesSent: cellBytesSent, multipathService: self.multipathService, serverName: bestServer, startTime: self.startTime, testResults: testResults)
            if self.userInterrupted {
                benchmark.userInterrupted = true
            }
            Utils.sendToServer(benchmark: benchmark, tests: self.tests)
            benchmark.save()
            self.cellTimer?.invalidate()
            self.cellTimer = nil
            self.chartTimer?.invalidate()
            self.chartTimer = nil
            print("Tests done")
            NotificationCenter.default.post(name: Utils.TestsLaunchedNotification, object: nil, userInfo: ["startNewTestsEnabled": true])
            NotificationCenter.default.removeObserver(self)
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                self.progress.setProgress(value: 100.0, animationDuration: 0.2) {}
                self.navigationItem.hidesBackButton = false
                let resultLabelViewController = self.currentResultViewController as! ResultLabelViewController
                resultLabelViewController.label.text = "Test completed."
            }
        }
    }

    // MARK: Protocols    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tests.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Table view cells are reused and should be dequeued using a cell identifier.
        let cellIdentifier = "StaticTestTableViewCell"
        guard let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath) as? StaticTestTableViewCell else {
            fatalError("The dequeued cell is not an instance of StaticTestTableViewCell.")
        }
        
        let test = tests[indexPath.row]
        
        cell.nameLabel.text = test.getDescription()
        // Load images
        let bundle = Bundle(for: type(of: self))
        let okTest = UIImage(named: "ok_test", in: bundle, compatibleWith: self.traitCollection)
        let failedTest = UIImage(named: "failed_test", in: bundle, compatibleWith: self.traitCollection)
        let runningTest = UIImage(named: "running_test", in: bundle, compatibleWith: self.traitCollection)
        let comingTest = UIImage(named: "blank", in: bundle, compatibleWith: self.traitCollection)
        
        if indexPath.row == self.runningIndex && !stoppedTests {
            cell.resultImageView.image = runningTest
        } else if indexPath.row < self.runningIndex {
            let result = test.getTestResult()
            if result.succeeded() && indexPath.row != stoppedIndex {
                cell.resultImageView.image = okTest
            } else {
                cell.resultImageView.image = failedTest
            }
        } else {
            cell.resultImageView.image = comingTest
        }
        if let shortResult = test.getShortResult() {
            cell.resultLabel.text = shortResult
        } else {
            cell.resultLabel.text = ""
        }
        
        return cell
    }
    
    @objc
    func updateChart() {
        guard let resultLineChartViewController = self.currentResultViewController as? ResultLineChartViewController else {
            return
        }
        if runningIndex >= 0 && runningIndex < tests.count {
            let test = self.tests[runningIndex]
            if let chartEntries = test.getChartData() {
                resultLineChartViewController.updateChart(chartEntries: chartEntries)
            }
        }
    }
    
    @objc
    func probeCellular() {
        let cellStatus = UIDevice.current.hasCellularConnectivity
        // For debug
        // debugCount += 1
        //if debugCount >= 5 {
        //    print("Will debug")
        //    Utils.getDebug()
        //    debugCount = 0
        //}
        if cellStatus != wasCellularOn {
            let reachabilityStatus = internetReachability.currentReachabilityStatus()
            let conn = Connectivity.getCurrentConnectivity(reachabilityStatus: reachabilityStatus)
            connectivities.append(conn)
            print("Cellular changed! In static tests, this should abort the test!")
            for i in 0..<tests.count {
                QuictrafficNotifyReachability(tests[i].getNotifyID())
            }
            stopTests()
        }
    }
    
    @IBAction func stopTests(_ sender: UIBarButtonItem) {
        sender.isEnabled = false
        if finalizing {
            return
        }
        self.userInterrupted = true
        for i in 0..<allTests.count {
            let test = allTests[i]
            test.stop()
        }
    }
    
    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

}
