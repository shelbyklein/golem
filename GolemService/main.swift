import Foundation
import Darwin
var service:GolemJobs?
var control:GolemControl?
Task{@MainActor in
    do {
        #if DEBUG
        if RuntimePaths.data.path.hasPrefix("/tmp/golem-"),(ProcessInfo.processInfo.environment["GOLEM_TEST_JOB"] != nil || ProcessInfo.processInfo.environment["GOLEM_TEST_DISABLE_AUTOMATION"]=="1") {
            AppPreferences.defaults.setVolatileDomain(["dotCheckIns":false,"dotEmailWatch":false,"dotWatchWaiting":false,"dotSummarizeFinished":false],forName:UserDefaults.argumentDomain)
            if ProcessInfo.processInfo.environment["GOLEM_TEST_EMAIL"]=="1",let fake=ProcessInfo.processInfo.environment["FAKE_PROVIDER"] {
                AppPreferences.defaults.setVolatileDomain(["dotCheckIns":false,"dotEmailWatch":true,"dotWatchWaiting":false,"dotSummarizeFinished":false,"codexPath":fake],forName:UserDefaults.argumentDomain)
            }
        }
        #endif
        #if DEBUG
        if RuntimePaths.data.path.hasPrefix("/tmp/golem-"),ProcessInfo.processInfo.environment["GOLEM_TEST_POLICIES"]=="1",let fake=ProcessInfo.processInfo.environment["FAKE_PROVIDER"] {
            AppPreferences.defaults.setVolatileDomain(["dotCheckIns":true,"dotCheckInTimes":[480],"dotEmailWatch":true,"dotWatchWaiting":true,"dotSummarizeFinished":true,"codexPath":fake,"easyCLIProxyEnabled":false],forName:UserDefaults.argumentDomain)
        }
        #endif
        let jobs=try GolemJobs(client:RuntimeClient.shared);service=jobs;jobs.start()
        let server=GolemControl(jobs);try server.start();control=server
        #if DEBUG
        if RuntimePaths.data.path.hasPrefix("/tmp/golem-"),let id=ProcessInfo.processInfo.environment["GOLEM_TEST_JOB"] {
            jobs.enqueue(id:id,label:"Headless fixture",text:"hello")
        }
        #endif
        print("golemd ready");fflush(stdout)
    }catch{fputs("golemd: \(error.localizedDescription)\n",stderr);exit(1)}
}
signal(SIGTERM,SIG_IGN)
let stop=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
stop.setEventHandler{MainActor.assumeIsolated{control?.stop();exit(0)}};stop.resume()
RunLoop.main.run()
