# iCloud/CloudKit Setup Guide

This guide explains how to set up iCloud with CloudKit for syncing listening statistics across devices.

## What Syncs via iCloud

| Data | Storage | CloudKit Sync |
|------|---------|---------------|
| Listening history | Core Data | Yes |
| Play counts | Core Data | Yes |
| Skip counts | Core Data | Yes |
| Music cache | SwiftData | No |
| Artwork cache | SwiftData | No |
| Catalog cache | SwiftData | No |

**Important**: Music files, artwork, and the catalog cache are stored locally only. Only listening statistics sync via iCloud.

## Prerequisites

- **Apple Developer account** (paid membership required)
- **Xcode 15+**
- **Physical device for testing** - CloudKit sync doesn't work reliably on the iOS Simulator

## 1. Create iCloud Container

1. Sign into the [Apple Developer Portal](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Profiles**
3. Select **Identifiers** in the sidebar
4. Click the **+** button to create a new identifier
5. Select **iCloud Containers** and click Continue
6. Enter your container identifier using the format:
   ```
   iCloud.com.yourcompany.AppName
   ```
7. Click **Continue**, then **Register**

## 2. Configure Xcode Project

### 2.1 Enable iCloud Capability

1. Open your project in Xcode
2. Select your **target** in the project navigator
3. Go to the **Signing & Capabilities** tab
4. Click **+ Capability**
5. Search for and add **iCloud**
6. In the iCloud section:
   - Check **CloudKit**
   - Under Containers, click the **+** button
   - Select your container (`iCloud.com.yourcompany.AppName`)

### 2.2 Entitlements File

Xcode automatically creates/updates your `.entitlements` file. Verify it contains:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.yourcompany.AppName</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
</dict>
</plist>
```

### 2.3 Background Modes (Optional)

To receive push notifications when data changes on other devices:

1. In **Signing & Capabilities**, add the **Background Modes** capability
2. Check **Remote notifications**

This adds to your entitlements:
```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

## 3. Core Data with CloudKit

### 3.1 Create Data Model

1. In Xcode, create a new file: **File > New > File**
2. Select **Data Model** under Core Data
3. Name it (e.g., `Analytics.xcdatamodeld`)

When creating entities for CloudKit:
- All attributes **must be optional** (CloudKit requirement)
- Use supported types: String, Integer, Double, Date, Binary Data, UUID
- Avoid transformable attributes when possible

Example entity for listening statistics:
```
Entity: ListeningRecord
Attributes:
  - trackId: String (optional)
  - playCount: Integer 64 (optional)
  - skipCount: Integer 64 (optional)
  - lastPlayed: Date (optional)
  - totalListenTime: Double (optional)
```

### 3.2 NSPersistentCloudKitContainer Setup

Create a persistence controller that uses CloudKit:

```swift
import CoreData

class AnalyticsStore {
    static let shared = AnalyticsStore()

    let container: NSPersistentCloudKitContainer

    init() {
        container = NSPersistentCloudKitContainer(name: "Analytics")

        // Configure for CloudKit
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("No persistent store description found")
        }

        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.yourcompany.AppName"
        )

        // Enable remote change notifications
        description.setOption(
            true as NSNumber,
            forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
        )

        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
        }

        // Automatically merge changes from CloudKit
        container.viewContext.automaticallyMergesChangesFromParent = true

        // Handle conflicts - remote changes win
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }
}
```

### 3.3 Listening for Remote Changes

To update the UI when data syncs from other devices:

```swift
import Combine

class StatisticsService: ObservableObject {
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Listen for remote changes
        NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange,
            object: AnalyticsStore.shared.container.persistentStoreCoordinator
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshStatistics()
        }
        .store(in: &cancellables)
    }

    func refreshStatistics() {
        // Fetch updated data and refresh UI
    }
}
```

## 4. SwiftData (Non-CloudKit) Separation

Keep local caches separate from CloudKit-synced data by explicitly disabling CloudKit:

```swift
import SwiftData

@MainActor
class CacheService {
    let container: ModelContainer

    init() {
        let config = ModelConfiguration(
            "LocalCache",
            cloudKitDatabase: .none  // Explicitly disable CloudKit
        )

        do {
            container = try ModelContainer(
                for: CachedTrack.self, CachedArtwork.self, CachedCatalog.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
```

## 5. Testing CloudKit

### CloudKit Dashboard

1. Go to [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard)
2. Select your container
3. Navigate to **Private Database** (user data syncs here)
4. Check **Records** to see synced data

### Testing Sync

1. Install the app on two devices with the same Apple ID
2. Generate listening data on Device A
3. Wait for sync (usually seconds to minutes)
4. Verify data appears on Device B

### Debug Logging

Enable CloudKit debugging in your scheme:
1. Edit Scheme > Run > Arguments
2. Add environment variable: `-com.apple.CoreData.CloudKitDebug 1`

## 6. Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| "No CloudKit container" error | Verify container ID matches in entitlements and code |
| Data not syncing | Check device is signed into iCloud with same Apple ID |
| Simulator not working | Use a physical device - CloudKit is unreliable on simulator |
| Merge conflicts | Ensure `mergePolicy` is set correctly |
| Attributes won't sync | Make sure all attributes are optional |

### Entitlement Errors

If you see entitlement errors:
1. Clean build folder (Cmd + Shift + K)
2. Delete derived data: `~/Library/Developer/Xcode/DerivedData`
3. Ensure your provisioning profile includes iCloud capability
4. Re-download provisioning profiles in Xcode

### Checking iCloud Status

```swift
import CloudKit

func checkiCloudStatus() {
    CKContainer.default().accountStatus { status, error in
        switch status {
        case .available:
            print("iCloud available")
        case .noAccount:
            print("No iCloud account signed in")
        case .restricted:
            print("iCloud restricted")
        case .couldNotDetermine:
            print("Could not determine iCloud status: \(error?.localizedDescription ?? "")")
        case .temporarilyUnavailable:
            print("iCloud temporarily unavailable")
        @unknown default:
            break
        }
    }
}
```

## 7. Privacy Considerations

- CloudKit data is stored in the user's private iCloud account
- Only the user can access their own listening statistics
- No server-side code or database management required
- Apple handles encryption and security

## Resources

- [Apple CloudKit Documentation](https://developer.apple.com/documentation/cloudkit)
- [NSPersistentCloudKitContainer](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer)
- [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard)
- [WWDC: Using Core Data with CloudKit](https://developer.apple.com/videos/play/wwdc2019/202/)
