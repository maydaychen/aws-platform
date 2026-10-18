@MainActor
enum ResourceListLoader {
    static func loadIfNeeded(
        service: AWSService,
        destination: WorkspaceDestination,
        isProfileReady: Bool,
        isNavigating: Bool,
        ec2: EC2ViewModel,
        lambda: LambdaViewModel,
        s3: S3ViewModel
    ) {
        guard destination == .resources, isProfileReady, !isNavigating else { return }
        switch service {
        case .ec2: ec2.loadIfNeeded()
        case .lambda: lambda.loadIfNeeded()
        case .s3: s3.loadIfNeeded()
        default: break
        }
    }
}
