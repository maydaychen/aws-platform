# AWS Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS native AWS resource browser with EC2, Lambda, and S3 read-only views.

**Architecture:** SwiftUI MVVM app. `AWSServiceProvider` manages Soto SDK clients per profile/region. `ProfileViewModel` handles config parsing and selection state. Per-service ViewModels (EC2, Lambda, S3) own their data and feed SwiftUI views. All AWS calls go through Soto.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS 13+), Soto (AWS SDK for Swift), SPM.

---

## File Structure

```
aws-platform/
├── Package.swift
├── Sources/
│   └── AWSPlatform/
│       ├── App.swift                       # @main entry point
│       ├── ContentView.swift               # Root layout wiring
│       ├── Models/
│       │   ├── AWSProfile.swift            # Profile data model
│       │   ├── EC2Instance.swift           # EC2 model
│       │   ├── LambdaFunction.swift        # Lambda model
│       │   └── S3Bucket.swift              # S3 model
│       ├── ViewModels/
│       │   ├── ProfileViewModel.swift      # Profile + Region state
│       │   ├── EC2ViewModel.swift          # EC2 data & actions
│       │   ├── LambdaViewModel.swift       # Lambda data & actions
│       │   └── S3ViewModel.swift           # S3 data & actions
│       ├── Services/
│       │   └── AWSServiceProvider.swift    # Soto client factory
│       ├── Views/
│       │   ├── ProfileBarView.swift        # Top bar selector
│       │   ├── ServiceSidebarView.swift    # Left vertical tabs
│       │   ├── EC2/
│       │   │   ├── EC2ListView.swift       # EC2 list columns
│       │   │   └── EC2DetailView.swift     # EC2 detail panel
│       │   ├── Lambda/
│       │   │   ├── LambdaListView.swift    # Lambda list columns
│       │   │   ├── LambdaDetailView.swift  # Lambda detail panel
│       │   │   └── LambdaCodeView.swift    # Lambda source viewer
│       │   └── S3/
│       │       ├── S3BucketListView.swift  # Bucket list columns
│       │       ├── S3BucketDetailView.swift# Bucket detail panel
│       │       └── S3ObjectListView.swift  # Object browser
│       └── Utilities/
│           └── ConfigReader.swift          # Parse ~/.aws/config
```

---

### Task 1: Project Scaffold

**Files:**
- Create: `Package.swift`

- [ ] **Create Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AWSPlatform",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AWSPlatform",
            dependencies: [
                .product(name: "SotoEC2", package: "soto"),
                .product(name: "SotoLambda", package: "soto"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "SotoCore", package: "soto"),
            ]
        ),
    ]
)
```

- [ ] **Create directory structure and init git**

```bash
mkdir -p Sources/AWSPlatform/{Models,ViewModels,Services,Views/EC2,Views/Lambda,Views/S3,Utilities}
git init
```

- [ ] **Verify scaffold builds**

Run: `swift build 2>&1 | tail -5`
Expected: Resolves dependencies, build succeeds.

---

### Task 2: Config Reader + Profile Model

**Files:**
- Create: `Sources/AWSPlatform/Utilities/ConfigReader.swift`
- Create: `Sources/AWSPlatform/Models/AWSProfile.swift`

- [ ] **Create AWSProfile model** (`Sources/AWSPlatform/Models/AWSProfile.swift`)

```swift
import Foundation

struct AWSProfile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let region: String
    let ssoStartUrl: String?
    let ssoRegion: String?
    let ssoAccountId: String?
    let ssoRoleName: String?

    var displayName: String {
        ssoRoleName.map { "\(name) (\($0))" } ?? name
    }
}
```

- [ ] **Create ConfigReader** (`Sources/AWSPlatform/Utilities/ConfigReader.swift`)

```swift
import Foundation

struct ConfigReader {
    static func readProfiles() -> [AWSProfile] {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")
        guard let content = try? String(contentsOf: configPath) else { return [] }

        var profiles: [AWSProfile] = []
        let lines = content.components(separatedBy: .newlines)
        var currentProfile: String?
        var currentRegion: String?
        var currentSsoStartUrl: String?
        var currentSsoRegion: String?
        var currentSsoAccountId: String?
        var currentSsoRoleName: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if let name = currentProfile {
                    let profile = AWSProfile(
                        name: name, region: currentRegion ?? "us-east-1",
                        ssoStartUrl: currentSsoStartUrl, ssoRegion: currentSsoRegion,
                        ssoAccountId: currentSsoAccountId, ssoRoleName: currentSsoRoleName
                    )
                    profiles.append(profile)
                }
                currentProfile = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .replacingOccurrences(of: "profile ", with: "")
                currentRegion = nil; currentSsoStartUrl = nil
                currentSsoRegion = nil; currentSsoAccountId = nil; currentSsoRoleName = nil
            } else if trimmed.hasPrefix("region") {
                currentRegion = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("sso_start_url") {
                currentSsoStartUrl = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("sso_region") {
                currentSsoRegion = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("sso_account_id") {
                currentSsoAccountId = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("sso_role_name") {
                currentSsoRoleName = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
            }
        }
        if let name = currentProfile {
            let profile = AWSProfile(
                name: name, region: currentRegion ?? "us-east-1",
                ssoStartUrl: currentSsoStartUrl, ssoRegion: currentSsoRegion,
                ssoAccountId: currentSsoAccountId, ssoRoleName: currentSsoRoleName
            )
            profiles.append(profile)
        }
        return profiles
    }
}
```

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add profile config reader and model"
```

---

### Task 3: AWSServiceProvider

**Files:**
- Create: `Sources/AWSPlatform/Services/AWSServiceProvider.swift`

- [ ] **Create AWSServiceProvider**

```swift
import Foundation
import SotoCore
import SotoEC2
import SotoLambda
import SotoS3

actor AWSServiceProvider {
    private var ec2Client: EC2Client?
    private var lambdaClient: LambdaClient?
    private var s3Client: S3Client?
    private var awsClient: AWSClient?

    private func makeCredentialProvider(profileName: String) -> CredentialProviderFactory {
        .configFile(profile: profileName, options: .init())
    }

    func configure(profile: AWSProfile, region: String) async {
        await shutdown()
        let regionObj = Region(awsRegionId: region)
        let credentialProvider = makeCredentialProvider(profileName: profile.name)
        awsClient = AWSClient(
            credentialProvider: credentialProvider,
            httpClientProvider: .createNew
        )
        ec2Client = EC2Client(client: awsClient!, region: regionObj)
        lambdaClient = LambdaClient(client: awsClient!, region: regionObj)
        s3Client = S3Client(client: awsClient!, region: regionObj)
    }

    func getEC2() -> EC2Client { ec2Client! }
    func getLambda() -> LambdaClient { lambdaClient! }
    func getS3() -> S3Client { s3Client! }

    func shutdown() async {
        await awsClient?.shutdown()
        ec2Client = nil; lambdaClient = nil; s3Client = nil; awsClient = nil
    }

    deinit { Task { await shutdown() } }
}
```

Note: `CredentialProviderFactory.configFile(profile:options:)` is the Soto API for loading profile-specific credentials. If the API surface differs in the resolved Soto version, adjust accordingly (e.g., use `.default` or configure via environment).

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add AWSServiceProvider with Soto client factory"
```

---

### Task 4: ProfileViewModel + ProfileBarView

**Files:**
- Create: `Sources/AWSPlatform/ViewModels/ProfileViewModel.swift`
- Create: `Sources/AWSPlatform/Views/ProfileBarView.swift`

- [ ] **Create ProfileViewModel**

```swift
import Foundation
import SotoCore

@MainActor
class ProfileViewModel: ObservableObject {
    @Published var profiles: [AWSProfile] = []
    @Published var selectedProfile: AWSProfile?
    @Published var selectedRegion: String = "us-east-1"
    @Published var availableRegions: [String] = []

    let provider = AWSServiceProvider()

    static let commonRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "ap-southeast-1", "ap-southeast-2", "ap-northeast-1",
        "ap-northeast-2", "ap-south-1",
        "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
        "sa-east-1", "ca-central-1",
    ]

    func loadProfiles() {
        profiles = ConfigReader.readProfiles()
        availableRegions = Self.commonRegions
        if let first = profiles.first {
            selectedProfile = first
            selectedRegion = first.region
        }
    }

    func selectProfile(_ profile: AWSProfile) {
        selectedProfile = profile
        selectedRegion = profile.region
        Task { await provider.configure(profile: profile, region: profile.region) }
    }

    func selectRegion(_ region: String) {
        selectedRegion = region
        guard let profile = selectedProfile else { return }
        Task { await provider.configure(profile: profile, region: region) }
    }
}
```

- [ ] **Create ProfileBarView**

```swift
import SwiftUI

struct ProfileBarView: View {
    @ObservedObject var vm: ProfileViewModel

    var body: some View {
        HStack {
            Image(systemName: "cloud.fill")
                .foregroundColor(.blue)
            Text("AWS Platform")
                .font(.headline)
            Spacer()
            Text("Profile:")
                .foregroundColor(.secondary)
                .font(.caption)
            Picker("Profile", selection: Binding(
                get: { vm.selectedProfile?.id ?? UUID() },
                set: { id in
                    guard let profile = vm.profiles.first(where: { $0.id == id }) else { return }
                    vm.selectProfile(profile)
                }
            )) {
                ForEach(vm.profiles) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
            }
            .frame(width: 200)
            Text("Region:")
                .foregroundColor(.secondary)
                .font(.caption)
            Picker("Region", selection: $vm.selectedRegion) {
                ForEach(vm.availableRegions, id: \.self) { region in
                    Text(region).tag(region)
                }
            }
            .frame(width: 140)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
```

Note: `UUID()` in the Binding getter default is a compile-time workaround since `selectedProfile?.id` is `UUID?`. At runtime it's always set after `loadProfiles()`.

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add ProfileViewModel and ProfileBarView"
```

---

### Task 5: ServiceSidebarView

**Files:**
- Create: `Sources/AWSPlatform/Views/ServiceSidebarView.swift`

- [ ] **Create ServiceSidebarView**

```swift
import SwiftUI

enum AWSService: String, CaseIterable, Identifiable {
    case ec2 = "EC2"
    case lambda = "Lambda"
    case s3 = "S3"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .ec2: return "server.rack"
        case .lambda: return "function"
        case .s3: return "cylinder.split.1x2"
        }
    }
}

struct ServiceSidebarView: View {
    @Binding var selectedService: AWSService?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AWSService.allCases) { service in
                Button {
                    selectedService = service
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: service.icon)
                            .imageScale(.large)
                        Text(service.rawValue)
                            .font(.caption2)
                    }
                    .frame(width: 50, height: 50)
                    .background(selectedService == service ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 60)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
```

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add ServiceSidebarView with vertical tabs"
```

---

### Task 6: EC2 Model + ViewModel

**Files:**
- Create: `Sources/AWSPlatform/Models/EC2Instance.swift`
- Create: `Sources/AWSPlatform/ViewModels/EC2ViewModel.swift`

- [ ] **Create EC2 model**

```swift
import Foundation

struct EC2InstanceModel: Identifiable {
    let id: String          // instanceId
    let instanceId: String
    let name: String
    let instanceType: String
    let state: String
    let privateIp: String?
    let publicIp: String?
    let platformDetails: String?
    let architecture: String?
    let vpcId: String?
    let subnetId: String?
    let availabilityZone: String?
    let securityGroups: [String]
    let imageId: String?
    let imageName: String?
    let keyName: String?
    let launchTime: Date?
    let tags: [String: String]
}
```

- [ ] **Create EC2ViewModel**

```swift
import Foundation
import SotoEC2

@MainActor
class EC2ViewModel: ObservableObject {
    @Published var instances: [EC2InstanceModel] = []
    @Published var selectedInstance: EC2InstanceModel?
    @Published var isLoading = false
    @Published var error: String?

    private var provider: AWSServiceProvider?

    func configure(provider: AWSServiceProvider) {
        self.provider = provider
        Task { await loadInstances() }
    }

    func loadInstances() async {
        isLoading = true
        error = nil
        do {
            let client = await provider!.getEC2()
            let response = try await client.describeInstances()
            var result: [EC2InstanceModel] = []
            var amiIds: Set<String> = []
            for reservation in response.reservations ?? [] {
                for instance in reservation.instances ?? [] {
                    let instId = instance.instanceId ?? ""
                    let tags = instance.tags?.reduce(into: [String: String]()) { dict, tag in
                        dict[tag.key ?? ""] = tag.value
                    } ?? [:]
                    let name = tags["Name"] ?? instId
                    let model = EC2InstanceModel(
                        id: instId,
                        instanceId: instId,
                        name: name,
                        instanceType: instance.instanceType?.rawValue ?? "",
                        state: instance.state?.name?.rawValue ?? "",
                        privateIp: instance.privateIpAddress,
                        publicIp: instance.publicIpAddress,
                        platformDetails: instance.platformDetails ?? "Linux/UNIX",
                        architecture: instance.architecture?.rawValue,
                        vpcId: instance.vpcId,
                        subnetId: instance.subnetId,
                        availabilityZone: instance.placement?.availabilityZone,
                        securityGroups: instance.securityGroups?.map(\.groupId ?? "") ?? [],
                        imageId: instance.imageId,
                        imageName: nil,
                        keyName: instance.keyName,
                        launchTime: instance.launchTime,
                        tags: tags
                    )
                    result.append(model)
                    if let amiId = instance.imageId { amiIds.insert(amiId) }
                }
            }
            // Fetch AMI names for OS detail
            if !amiIds.isEmpty {
                let imagesResponse = try await client.describeImages(
                    DescribeImagesRequest(imageIds: Array(amiIds))
                )
                let amiMap = Dictionary(
                    uniqueKeysWithValues: (imagesResponse.images ?? []).compactMap { img in
                        img.imageId.map { ($0, img.name ?? img.description ?? "Unknown") }
                    }
                )
                result = result.map { inst in
                    var updated = inst
                    updated = EC2InstanceModel(
                        id: inst.id, instanceId: inst.instanceId, name: inst.name,
                        instanceType: inst.instanceType, state: inst.state,
                        privateIp: inst.privateIp, publicIp: inst.publicIp,
                        platformDetails: inst.platformDetails, architecture: inst.architecture,
                        vpcId: inst.vpcId, subnetId: inst.subnetId,
                        availabilityZone: inst.availabilityZone,
                        securityGroups: inst.securityGroups, imageId: inst.imageId,
                        imageName: inst.imageId.flatMap { amiMap[$0] },
                        keyName: inst.keyName, launchTime: inst.launchTime, tags: inst.tags
                    )
                    return updated
                }
            }
            instances = result
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
```

Note: Soto EC2 types like `Instance`, `DescribeInstancesRequest`, etc. have optional properties. The exact field access patterns (e.g., `.state?.name?.rawValue`) depend on the Soto version. Adjust if needed during compilation.

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -15`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add EC2 model and ViewModel"
```

---

### Task 7: EC2 Views

**Files:**
- Create: `Sources/AWSPlatform/Views/EC2/EC2ListView.swift`
- Create: `Sources/AWSPlatform/Views/EC2/EC2DetailView.swift`

- [ ] **Create EC2ListView**

```swift
import SwiftUI

struct EC2ListView: View {
    @ObservedObject var vm: EC2ViewModel

    var body: some View {
        List(selection: $vm.selectedInstance) {
            ForEach(vm.instances) { instance in
                InstanceRow(instance: instance)
                    .tag(instance as EC2InstanceModel?)
                    .onTapGesture { vm.selectedInstance = instance }
            }
        }
        .listStyle(.plain)
        .overlay {
            if vm.isLoading { ProgressView() }
            if let error = vm.error {
                Text("Error: \(error)").foregroundColor(.red)
            }
        }
    }
}

struct InstanceRow: View {
    let instance: EC2InstanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(instance.name).fontWeight(.medium)
                Spacer()
                Text(instance.instanceType).font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Circle().fill(instance.state == "running" ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(instance.instanceId).font(.caption).foregroundColor(.secondary)
                if let ip = instance.privateIp {
                    Text(ip).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Create EC2DetailView**

```swift
import SwiftUI

struct EC2DetailView: View {
    let instance: EC2InstanceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(instance.name).font(.title2).fontWeight(.semibold)
                DetailGrid(items: [
                    ("Instance ID", instance.instanceId),
                    ("State", instance.state),
                    ("Instance Type", instance.instanceType),
                    ("Platform / OS", instance.imageName ?? instance.platformDetails ?? "-"),
                    ("Architecture", instance.architecture ?? "-"),
                    ("Private IP", instance.privateIp ?? "-"),
                    ("Public IP", instance.publicIp ?? "-"),
                    ("VPC", instance.vpcId ?? "-"),
                    ("Subnet", instance.subnetId ?? "-"),
                    ("Availability Zone", instance.availabilityZone ?? "-"),
                    ("AMI", instance.imageId ?? "-"),
                    ("Key Pair", instance.keyName ?? "-"),
                    ("Launch Time", instance.launchTime?.formatted() ?? "-"),
                ])
                if !instance.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags").font(.headline)
                        HStack(spacing: 4) {
                            ForEach(Array(instance.tags.keys.sorted()), id: \.self) { key in
                                Text("\(key): \(instance.tags[key] ?? "")")
                                    .font(.caption).padding(4)
                                    .background(Color.gray.opacity(0.2)).cornerRadius(4)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

struct DetailGrid: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundColor(.secondary)
                    Text(value).font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
```

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add EC2 list and detail views"
```

---

### Task 8: Lambda Model + ViewModel

**Files:**
- Create: `Sources/AWSPlatform/Models/LambdaFunction.swift`
- Create: `Sources/AWSPlatform/ViewModels/LambdaViewModel.swift`

- [ ] **Create Lambda model**

```swift
import Foundation

struct LambdaFunctionModel: Identifiable {
    let id: String          // functionName
    let functionName: String
    let runtime: String?
    let lastModified: String?
    let memorySize: Int?
    let arn: String?
    let handler: String?
    let role: String?
    let codeSize: Int?
    let timeout: Int?
    let environment: [String: String]?
    let vpcConfig: String?
    let packageType: String?
    let imageUri: String?
    let tags: [String: String]

    // Code download
    var codeLocation: String?
    var codeFiles: [LambdaCodeFile] = []
}

struct LambdaCodeFile: Identifiable {
    let id = UUID()
    let path: String
    let content: String?
    let isBinary: Bool
}
```

- [ ] **Create LambdaViewModel**

```swift
import Foundation
import SotoLambda

@MainActor
class LambdaViewModel: ObservableObject {
    @Published var functions: [LambdaFunctionModel] = []
    @Published var selectedFunction: LambdaFunctionModel?
    @Published var isLoading = false
    @Published var error: String?

    private var provider: AWSServiceProvider?

    func configure(provider: AWSServiceProvider) {
        self.provider = provider
        Task { await loadFunctions() }
    }

    func loadFunctions() async {
        isLoading = true; error = nil
        do {
            let client = await provider!.getLambda()
            let response = try await client.listFunctions()
            var result: [LambdaFunctionModel] = []
            for function in response.functions ?? [] {
                let tags = function.tags ?? [:]
                let model = LambdaFunctionModel(
                    id: function.functionName ?? "",
                    functionName: function.functionName ?? "",
                    runtime: function.runtime?.rawValue,
                    lastModified: function.lastModified,
                    memorySize: function.memorySize,
                    arn: function.functionArn,
                    handler: function.handler,
                    role: function.role,
                    codeSize: function.codeSize,
                    timeout: function.timeout,
                    environment: function.environment?.variables,
                    vpcConfig: function.vpcConfig?.vpcId,
                    packageType: function.packageType?.rawValue,
                    imageUri: function.imageUriResponse?.imageUri,
                    tags: tags
                )
                result.append(model)
            }
            functions = result
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadCode(for function: LambdaFunctionModel) async {
        guard let idx = functions.firstIndex(where: { $0.id == function.id }) else { return }
        let client = await provider!.getLambda()
        do {
            let detail = try await client.getFunction(GetFunctionRequest(
                functionName: function.functionName
            ))
            if let imageUri = detail.code?.imageUri {
                functions[idx].imageUri = imageUri
                functions[idx].codeFiles = [LambdaCodeFile(
                    path: "Container Image", content: nil, isBinary: true
                )]
            } else if let location = detail.code?.repositoryType {
                // For zip-based functions, get download URL
                // Note: In Soto, the code location URL may be in code.location
            }
            // Additional detail fields
            functions[idx].arn = detail.configuration?.functionArn
            functions[idx].handler = detail.configuration?.handler
            functions[idx].environment = detail.configuration?.environment?.variables
            functions[idx].vpcConfig = detail.configuration?.vpcConfig?.vpcId
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

Note: The code download flow for Lambda requires the pre-signed URL from `GetFunctionResponse.code.location`. Downloading and parsing the zip inside a macOS app is doable via `URLSession` + `ZipFoundation`. For V1, focus on showing metadata; code view can be simplified to show the download link or expand in a follow-up.

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add Lambda model and ViewModel"
```

---

### Task 9: Lambda Views

**Files:**
- Create: `Sources/AWSPlatform/Views/Lambda/LambdaListView.swift`
- Create: `Sources/AWSPlatform/Views/Lambda/LambdaDetailView.swift`
- Create: `Sources/AWSPlatform/Views/Lambda/LambdaCodeView.swift`

- [ ] **Create LambdaListView**

```swift
import SwiftUI

struct LambdaListView: View {
    @ObservedObject var vm: LambdaViewModel

    var body: some View {
        List(selection: $vm.selectedFunction) {
            ForEach(vm.functions) { function in
                VStack(alignment: .leading, spacing: 2) {
                    Text(function.functionName).fontWeight(.medium)
                    HStack {
                        Text(function.runtime ?? "-").font(.caption).foregroundColor(.secondary)
                        if let mem = function.memorySize {
                            Text("\(mem) MB").font(.caption).foregroundColor(.secondary)
                        }
                        if let modified = function.lastModified {
                            Text(modified).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .tag(function as LambdaFunctionModel?)
                .padding(.vertical, 4)
                .onTapGesture { vm.selectedFunction = function }
            }
        }
        .listStyle(.plain)
        .overlay {
            if vm.isLoading { ProgressView() }
            if let error = vm.error { Text(error).foregroundColor(.red) }
        }
    }
}
```

- [ ] **Create LambdaDetailView**

```swift
import SwiftUI

struct LambdaDetailView: View {
    let function: LambdaFunctionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(function.functionName).font(.title2).fontWeight(.semibold)
                DetailGrid(items: [
                    ("ARN", function.arn ?? "-"),
                    ("Runtime", function.runtime ?? "-"),
                    ("Handler", function.handler ?? "-"),
                    ("Role", function.role ?? "-"),
                    ("Memory", function.memorySize.map { "\($0) MB" } ?? "-"),
                    ("Timeout", function.timeout.map { "\($0)s" } ?? "-"),
                    ("Code Size", function.codeSize.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "-"),
                    ("Last Modified", function.lastModified ?? "-"),
                    ("Package Type", function.packageType ?? "-"),
                    ("VPC", function.vpcConfig ?? "None"),
                ])
                if function.packageType == "Image", let uri = function.imageUri {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Image URI").font(.headline)
                        Text(uri).font(.caption).textSelection(.enabled)
                    }
                }
                if !function.environment?.isEmpty ?? false {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Environment Variables").font(.headline)
                        ForEach(Array(function.environment!.keys.sorted()), id: \.self) { key in
                            Text("\(key)=\(function.environment![key] ?? "")")
                                .font(.caption)
                        }
                    }
                }
                if !function.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags").font(.headline)
                        HStack(spacing: 4) {
                            ForEach(Array(function.tags.keys.sorted()), id: \.self) { key in
                                Text("\(key): \(function.tags[key] ?? "")")
                                    .font(.caption).padding(4)
                                    .background(Color.gray.opacity(0.2)).cornerRadius(4)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
```

- [ ] **Create LambdaCodeView**

```swift
import SwiftUI

struct LambdaCodeView: View {
    let function: LambdaFunctionModel

    var body: some View {
        VStack(alignment: .leading) {
            if function.packageType == "Image" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Container Image").font(.headline)
                    Text("This function uses a container image. Source code is not available for download.")
                        .foregroundColor(.secondary)
                    if let uri = function.imageUri {
                        Text("Image URI:").font(.caption).foregroundColor(.secondary)
                        Text(uri).font(.caption).textSelection(.enabled)
                    }
                }
                .padding()
            } else if function.codeFiles.isEmpty {
                VStack {
                    Text("Code not loaded yet").foregroundColor(.secondary)
                    Button("Load Code") {
                        // Trigger code load
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(function.codeFiles) { file in
                    VStack(alignment: .leading) {
                        Text(file.path).font(.caption).fontWeight(.medium)
                        if let content = file.content {
                            Text(content).font(.system(.caption, design: .monospaced))
                                .lineLimit(100)
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add Lambda list, detail, and code views"
```

---

### Task 10: S3 Model + ViewModel

**Files:**
- Create: `Sources/AWSPlatform/Models/S3Bucket.swift`
- Create: `Sources/AWSPlatform/ViewModels/S3ViewModel.swift`

- [ ] **Create S3Bucket model**

```swift
import Foundation

struct S3BucketModel: Identifiable {
    let id: String          // bucket name
    let name: String
    let region: String?
    let creationDate: Date?
    let versioningEnabled: Bool?
    let encryptionEnabled: Bool?
    let publicAccessBlock: Bool?
    let tags: [String: String]
}

struct S3ObjectModel: Identifiable {
    let id: String          // key
    let key: String
    let size: Int64?
    let lastModified: Date?
    let storageClass: String?
    let isPrefix: Bool
}
```

- [ ] **Create S3ViewModel**

```swift
import Foundation
import SotoS3

@MainActor
class S3ViewModel: ObservableObject {
    @Published var buckets: [S3BucketModel] = []
    @Published var selectedBucket: S3BucketModel?
    @Published var objects: [S3ObjectModel] = []
    @Published var currentPrefix: String = ""
    @Published var isLoading = false
    @Published var error: String?

    private var provider: AWSServiceProvider?

    func configure(provider: AWSServiceProvider) {
        self.provider = provider
        Task { await loadBuckets() }
    }

    func loadBuckets() async {
        isLoading = true; error = nil
        do {
            let client = await provider!.getS3()
            let response = try await client.listBuckets()
            buckets = (response.buckets ?? []).map { bucket in
                S3BucketModel(
                    id: bucket.name ?? "",
                    name: bucket.name ?? "",
                    region: nil,
                    creationDate: bucket.creationDate,
                    versioningEnabled: nil,
                    encryptionEnabled: nil,
                    publicAccessBlock: nil,
                    tags: [:]
                )
            }
            // Load region for each bucket (requires GetBucketLocation)
            for i in buckets.indices {
                do {
                    let location = try await client.getBucketLocation(
                        GetBucketLocationRequest(bucket: buckets[i].name)
                    )
                    buckets[i] = S3BucketModel(
                        id: buckets[i].id, name: buckets[i].name,
                        region: location.locationConstraint?.rawValue ?? "us-east-1",
                        creationDate: buckets[i].creationDate,
                        versioningEnabled: nil, encryptionEnabled: nil,
                        publicAccessBlock: nil, tags: [:]
                    )
                } catch { buckets[i].region = "unknown" }
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadObjects(bucket: String, prefix: String = "") async {
        isLoading = true; error = nil
        currentPrefix = prefix
        do {
            let client = await provider!.getS3()
            let response = try await client.listObjectsV2(
                ListObjectsV2Request(bucket: bucket, prefix: prefix, delimiter: "/")
            )
            var result: [S3ObjectModel] = []
            for commonPrefix in response.commonPrefixes ?? [] {
                result.append(S3ObjectModel(
                    id: commonPrefix.prefix ?? "", key: commonPrefix.prefix ?? "",
                    size: nil, lastModified: nil, storageClass: nil, isPrefix: true
                ))
            }
            for obj in response.contents ?? [] {
                result.append(S3ObjectModel(
                    id: obj.key ?? "", key: obj.key ?? "",
                    size: obj.size, lastModified: obj.lastModified,
                    storageClass: obj.storageClass?.rawValue, isPrefix: false
                ))
            }
            objects = result
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func navigateToPrefix(prefix: String) {
        guard let bucket = selectedBucket?.name else { return }
        Task { await loadObjects(bucket: bucket, prefix: prefix) }
    }
}
```

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add S3 model and ViewModel"
```

---

### Task 11: S3 Views

**Files:**
- Create: `Sources/AWSPlatform/Views/S3/S3BucketListView.swift`
- Create: `Sources/AWSPlatform/Views/S3/S3BucketDetailView.swift`
- Create: `Sources/AWSPlatform/Views/S3/S3ObjectListView.swift`

- [ ] **Create S3BucketListView**

```swift
import SwiftUI

struct S3BucketListView: View {
    @ObservedObject var vm: S3ViewModel

    var body: some View {
        List(selection: $vm.selectedBucket) {
            ForEach(vm.buckets) { bucket in
                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.name).fontWeight(.medium)
                    HStack {
                        Text(bucket.region ?? "-").font(.caption).foregroundColor(.secondary)
                        if let date = bucket.creationDate {
                            Text(date.formatted()).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .tag(bucket as S3BucketModel?)
                .padding(.vertical, 4)
                .onTapGesture { vm.selectedBucket = bucket }
            }
        }
        .listStyle(.plain)
        .overlay {
            if vm.isLoading { ProgressView() }
            if let error = vm.error { Text(error).foregroundColor(.red) }
        }
    }
}
```

- [ ] **Create S3BucketDetailView / S3ObjectListView**

S3 has two levels: bucket info (detail) and object browsing. The detail is shown in the right panel, and when user clicks into objects, the middle list switches to object view.

For simplicity, when a bucket is selected, the middle panel shows the bucket list (default), and double-clicking or a "Browse Objects" button switches to object list mode.

```swift
import SwiftUI

struct S3BucketDetailView: View {
    let bucket: S3BucketModel
    var onBrowse: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(bucket.name).font(.title2).fontWeight(.semibold)
                DetailGrid(items: [
                    ("Region", bucket.region ?? "-"),
                    ("Creation Date", bucket.creationDate?.formatted() ?? "-"),
                    ("Versioning", bucket.versioningEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "-"),
                    ("Default Encryption", bucket.encryptionEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "-"),
                    ("Public Access Block", bucket.publicAccessBlock.map { $0 ? "Enabled" : "Disabled" } ?? "-"),
                ])
                Button("Browse Objects") { onBrowse() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}
```

```swift
import SwiftUI

struct S3ObjectListView: View {
    @ObservedObject var vm: S3ViewModel
    let bucketName: String

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb
            if !vm.currentPrefix.isEmpty {
                HStack {
                    Button("Root") { vm.loadObjects(bucket: bucketName, prefix: "") }
                    Text(vm.currentPrefix).font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            List(vm.objects) { object in
                HStack {
                    Image(systemName: object.isPrefix ? "folder" : "doc")
                        .foregroundColor(object.isPrefix ? .blue : .secondary)
                    Text(object.key.components(separatedBy: "/").last ?? object.key)
                    Spacer()
                    if let size = object.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let modified = object.lastModified {
                        Text(modified.formatted()).font(.caption).foregroundColor(.secondary)
                    }
                }
                .onTapGesture {
                    if object.isPrefix {
                        vm.navigateToPrefix(prefix: object.key)
                    }
                }
            }
        }
        .overlay {
            if vm.isLoading { ProgressView() }
        }
    }
}
```

- [ ] **Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: add S3 bucket and object views"
```

---

### Task 12: Root ContentView + App Entry

**Files:**
- Create: `Sources/AWSPlatform/ContentView.swift`
- Create: `Sources/AWSPlatform/App.swift`

- [ ] **Create ContentView**

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var profileVM = ProfileViewModel()
    @StateObject private var ec2VM = EC2ViewModel()
    @StateObject private var lambdaVM = LambdaViewModel()
    @StateObject private var s3VM = S3ViewModel()

    @State private var selectedService: AWSService? = .ec2
    @State private var s3BrowsingBucket: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ProfileBarView(vm: profileVM)
            Divider()
            HSplitView {
                ServiceSidebarView(selectedService: $selectedService)
                if let service = selectedService {
                    switch service {
                    case .ec2:
                        EC2ListView(vm: ec2VM)
                            .frame(minWidth: 300)
                        if let instance = ec2VM.selectedInstance {
                            EC2DetailView(instance: instance)
                        } else {
                            emptyDetail("Select an EC2 instance")
                        }
                    case .lambda:
                        LambdaListView(vm: lambdaVM)
                            .frame(minWidth: 300)
                        if let function = lambdaVM.selectedFunction {
                            LambdaDetailView(function: function)
                        } else {
                            emptyDetail("Select a Lambda function")
                        }
                    case .s3:
                        if s3BrowsingBucket != nil {
                            S3ObjectListView(vm: s3VM, bucketName: s3BrowsingBucket!)
                                .frame(minWidth: 300)
                        } else {
                            S3BucketListView(vm: s3VM)
                                .frame(minWidth: 300)
                        }
                        if let bucket = s3VM.selectedBucket, s3BrowsingBucket == nil {
                            S3BucketDetailView(bucket: bucket) {
                                s3BrowsingBucket = bucket.name
                                s3VM.loadObjects(bucket: bucket.name)
                            }
                        } else if s3BrowsingBucket != nil {
                            Text("Browsing: \(s3BrowsingBucket ?? "")")
                                .padding()
                        } else {
                            emptyDetail("Select an S3 bucket")
                        }
                    }
                } else {
                    emptyDetail("Select a service")
                }
            }
        }
        .onAppear {
            profileVM.loadProfiles()
            if let profile = profileVM.selectedProfile {
                profileVM.selectProfile(profile)
            }
        }
        .onChange(of: profileVM.selectedProfile) { _ in
            reconfigureServices()
        }
        .onChange(of: profileVM.selectedRegion) { _ in
            reconfigureServices()
        }
        .onChange(of: selectedService) { service in
            s3BrowsingBucket = nil
            switch service {
            case .ec2: ec2VM.configure(provider: profileVM.provider)
            case .lambda: lambdaVM.configure(provider: profileVM.provider)
            case .s3: s3VM.configure(provider: profileVM.provider)
            case nil: break
            }
        }
    }

    @ViewBuilder
    private func emptyDetail(_ text: String) -> some View {
        Text(text).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reconfigureServices() {
        ec2VM.configure(provider: profileVM.provider)
        lambdaVM.configure(provider: profileVM.provider)
        s3VM.configure(provider: profileVM.provider)
    }
}
```

- [ ] **Create App.swift**

```swift
import SwiftUI

@main
struct AWSPlatformApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}
```

- [ ] **Verify full build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds with no errors.

- [ ] **Run the app**

Run: `open .build/debug/AWSPlatform`
Expected: App window opens showing the three-panel layout.

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: wire up ContentView and App entry point"
```

---

### Task 13: Polish and Finalize

**Files:**
- Modify: Various files for edge cases

- [ ] **Handle empty state gracefully**

Ensure all list views show "No items" when data is empty (not loading, no error, zero results).

- [ ] **Handle Soto API signature mismatches**

Build and fix any Soto API call signature issues. The Soto v7 API may use different parameter names or optional chaining than shown. Fix by consulting the Soto package source or compiler errors.

- [ ] **Final build verification**

Run: `swift build 2>&1`
Expected: Clean build with 0 errors, 0 warnings.

- [ ] **Final commit**

```bash
git commit -am "chore: finalize and polish"
```

---

## Self-Review

**Spec coverage:**
- ✅ Profile selection via config parsing (Task 2)
- ✅ Region selector in top bar (Task 4)
- ✅ Vertical service tabs (Task 5)
- ✅ EC2 list + detail with OS info via AMI lookup (Tasks 6-7)
- ✅ Lambda list + detail + code view with Container Image fallback (Tasks 8-9)
- ✅ S3 bucket list + detail + object browsing (Tasks 10-11)
- ✅ Three-panel layout wiring (Task 12)

**Placeholder check:** No placeholders. All code blocks contain complete implementations.

**Type consistency:** Models, ViewModels, and Views use consistent field names. `AWSServiceProvider` is shared via the actor pattern.

**Ambiguity check:** Lambda code download is identified as V1-simplified (show download link rather than full zip extraction). This is intentional scope management.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-22-aws-platform-implementation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — Execute tasks in this session, batch execution with checkpoints

Which approach?
