import Foundation
import Darwin

@MainActor final class GolemControl {
    let jobs:GolemJobs
    private var fd:Int32 = -1
    private var source:DispatchSourceRead?
    private var peers:[UUID:RuntimePeer]=[:]
    private var authenticated:Set<UUID>=[]
    private let socket=RuntimePaths.data.appendingPathComponent("golem.sock")
    init(_ jobs:GolemJobs){self.jobs=jobs}
    func start() throws {
        guard let fd=UnixSocket.listen(at:socket) else{throw RuntimeFailure("Cannot listen on Golem socket")}
        self.fd=fd;_ = fcntl(fd,F_SETFL,O_NONBLOCK)
        let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:.main)
        source.setEventHandler{[weak self] in MainActor.assumeIsolated{self?.accept()}};source.resume();self.source=source
    }
    func stop(){source?.cancel();source=nil;for peer in peers.values{peer.stop()};peers.removeAll();if fd>=0{close(fd);fd = -1};unlink(socket.path);jobs.stop()}
    private func accept(){
        while true {
            let socketFD=Darwin.accept(fd,nil,nil);if socketFD<0{return}
            var uid:uid_t=0,gid:gid_t=0
            guard getpeereid(socketFD,&uid,&gid)==0,uid==getuid(),peers.count<16 else{close(socketFD);continue}
            _ = fcntl(socketFD,F_SETFL,fcntl(socketFD,F_GETFL) & ~O_NONBLOCK)
            var signal:Int32=1;setsockopt(socketFD,SOL_SOCKET,SO_NOSIGPIPE,&signal,socklen_t(MemoryLayout<Int32>.size))
            var timeout=timeval(tv_sec:5,tv_usec:0);setsockopt(socketFD,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
            let peer=RuntimePeer(fd:socketFD,trustedUI:RuntimePeerIdentity.trustedUI(socketFD,root:RuntimePaths.data,allowDaemon:true));peers[peer.id]=peer
            Thread{[weak self,peer] in
                var buffer=Data(),bytes=[UInt8](repeating:0,count:4096)
                while true {
                    let n=read(socketFD,&bytes,bytes.count);if n<0,errno==EINTR{continue};if n<=0{break}
                    buffer.append(contentsOf:bytes.prefix(n));if buffer.count>65536{break}
                    while let end=buffer.firstIndex(of:10){
                        let line=buffer.subdata(in:buffer.startIndex..<end);buffer.removeSubrange(buffer.startIndex...end)
                        guard let request=try? JSONDecoder().decode(RuntimeRequest.self,from:line) else{break}
                        DispatchQueue.main.async{MainActor.assumeIsolated{self?.handle(request,peer)}}
                    }
                }
                peer.stop();DispatchQueue.main.async{MainActor.assumeIsolated{self?.peers[peer.id]=nil;self?.authenticated.remove(peer.id)}}
            }.start()
        }
    }
    private func handle(_ request:RuntimeRequest,_ peer:RuntimePeer){
        do {
            guard request.version==1 else{throw RuntimeFailure("unsupported_version")}
            if request.operation=="hello" {
                guard peer.isTrustedUI,request.body["role"]?.string=="ui" else{throw RuntimeFailure("permission_denied")}
                authenticated.insert(peer.id);peer.send(RuntimeReply(id:request.id,result:["version":1]));return
            }
            guard authenticated.contains(peer.id) else{throw RuntimeFailure("permission_denied")}
            var result:JSON=["ok":true]
            switch request.operation {
            case "subscribe":result=["events":[],"sequence":0,"resync":true]
            case "health":
                let keys=["dotCheckIns","dotWatchWaiting","dotSummarizeFinished","dotEmailWatch"]
                var preferences:[String:JSON]=[:]
                for key in keys{preferences[key] = .bool(AppPreferences.defaults.object(forKey:key) as? Bool ?? true)}
                result=["paused":.bool(jobs.state.paused),"problem":(jobs.state.emailProblem ?? jobs.state.problem).map(JSON.string) ?? .null,
                        "jobs":.number(Double(jobs.state.jobs.count)),"preferences":.object(preferences),
                        "checkInTimes":try .value(AppPreferences.defaults.array(forKey:"dotCheckInTimes") as? [Int] ?? [480,900]),
                        "emailThrough":jobs.state.emailThrough.map{.string(ISO8601DateFormatter().string(from:$0))} ?? .null,
                        "emailAttempt":jobs.state.emailAttempt.map{.string(ISO8601DateFormatter().string(from:$0))} ?? .null,
                        "emailProblem":jobs.state.emailProblem.map(JSON.string) ?? .null,
                        "emailAccounts":try .value(jobs.state.emailAccounts ?? []),
                        "sweeping":.bool(jobs.isSweeping)]
            case "journal":result=try .value(jobs.entries)
            case "pause", "checkIn", "sweep", "settings", "stop":
                result=try jobs.executeControl(request) {
                    switch request.operation {
                    case "pause":self.jobs.pause(request.body["paused"]?.bool ?? true)
                    case "checkIn":self.jobs.checkInNow()
                    case "sweep":self.jobs.sweepNow()
                    case "settings":try self.jobs.settings(request.body)
                    default:self.jobs.pause(true)
                    }
                    return ["ok":true]
                }
                if request.operation=="stop" {
                    peer.send(RuntimeReply(id:request.id,result:result))
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.stop();exit(0)};return
                }
            default:throw RuntimeFailure("unsupported_operation")
            }
            peer.send(RuntimeReply(id:request.id,result:result))
        }catch{peer.send(RuntimeReply(id:request.id,error:error.localizedDescription))}
    }
}
