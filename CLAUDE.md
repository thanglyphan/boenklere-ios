# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Boenklere is an iOS marketplace app built with SwiftUI that enables users to browse, list, and transact items through a location-based map interface. Features include real-time messaging, Stripe payments, and user reviews.

**Backend API:** The server-side API is located in the sibling folder `../boenklere-api`.

## Build Commands

```bash
# Build the project
xcodebuild -project boenklere.xcodeproj -scheme boenklere -configuration Debug build

# Build for simulator
xcodebuild -project boenklere.xcodeproj -scheme boenklere -destination 'platform=iOS Simulator,name=iPhone 15' build

# Clean build
xcodebuild -project boenklere.xcodeproj -scheme boenklere clean build
```

Open `boenklere.xcodeproj` in Xcode for full development (⌘+R to run, ⌘+B to build).

## Architecture

**Pattern:** MVVM with SwiftUI and reactive programming via `@Published` properties and `ObservableObject`.

### Core Components

| Layer | Files | Responsibility |
|-------|-------|----------------|
| App Entry | `BoenklereApp.swift`, `AppDelegate.swift` | App lifecycle, push notifications, environment setup |
| State | `Managers/AuthenticationManager.swift` | Auth state, user preferences, session sync |
| Network | `Services/APIService.swift` | REST API client, data models, Stripe integration |
| UI | `Views/` | SwiftUI views (MapKit, messaging, auth) |

### Key Files

- **MainMapView.swift** - Primary map interface with listing clustering, location tracking, sheet navigation
- **ChatSheet.swift** - Messaging UI with WebSocket real-time updates (`ChatSocketClient`), Stripe payment flow
- **AuthenticationManager.swift** - Apple Sign In, UserDefaults persistence, device token registration
- **APIService.swift** - Singleton REST client with all API methods and data models

### Data Flow

```
AuthenticationManager (state) → APIService (network)
        ↓
    UserDefaults (persistence)
        ↓
    MainMapView (map UI)
        ↓
    ChatSheet (messaging + payments via WebSocket)
```

### Notification System

Uses `NotificationCenter` for cross-component communication:
- `.didRegisterDeviceToken` - Push token registered
- `.didReceiveChatNotification` - New message deep link
- `.didReceiveListingNotification` - Listing notification deep link
- `.didMarkConversationRead` - Conversation read status
- `.openMyListings` - Navigate to user's listings

### External Dependencies

- **Apple Frameworks:** SwiftUI, MapKit, CoreLocation, AuthenticationServices, UserNotifications, PhotosUI, SafariServices
- **Third-Party:** Stripe Payment Sheet (integrated directly, no package manager)

## Configuration

API base URL is configured via Info.plist `API_BASE_URL` key (defaults to `http://localhost:8080`).

Required capabilities:
- Location (when in use)
- Push notifications (background mode enabled)
- App Transport Security allows local networking for development
