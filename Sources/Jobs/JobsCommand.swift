import Foundation
import Vapor

public struct JobsCommand: Command {
    public var arguments: [CommandArgument] = []
    public var options: [CommandOption] {
        return [
            CommandOption.value(name: "queue")
        ]
    }

    public var help: [String] = ["Runs queued worker jobs"]
    
    public init() { }
    
    public func run(using context: CommandContext) throws -> EventLoopFuture<Void> {
        let container = context.container
        let eventLoop = container.eventLoop
        
        let queueService = try container.make(QueueService.self)
        let promise = eventLoop.newPromise(Void.self)
        let jobContext = JobContext()
        let console = context.console
        let queue = QueueType(name: context.options["queue"] ?? "default")
        
        let key = queue.makeKey(with: queueService.persistenceKey)
        _ = eventLoop.scheduleRepeatedTask(initialDelay: .seconds(0), delay: queueService.refreshInterval) { task -> EventLoopFuture<Void> in
            do {
                return try queueService.persistenceLayer.get(key: key, worker: container).flatMap { job in
                    //No job found, go to the next iteration
                    guard let job = job else { return container.future() }
                    
                    console.info("Dequeing Job", newLine: true)
                    return try job
                        .dequeue(context: jobContext, worker: container)
                        .flatMap { _ in
                            let jobData = JobData(key: key, data: job)
                            let data = try JSONEncoder().encode(jobData)
                            guard let jobString =  String(data: data, encoding: .utf8) else { throw Abort(.internalServerError) }
                            
                            return try queueService.persistenceLayer.completed(key: key, jobString: jobString, worker: container)
                        }
                        .catchFlatMap { error in
                            console.error("Job error: \(error)", newLine: true)
                            return job.error(context: jobContext, error: error, worker: container).transform(to: ())
                    }
                }
            } catch {
                //handle error somehow
                console.error("Job error: \(error)", newLine: true)
                return container.future()
            }
        }
        
        return promise.futureResult
    }
}
