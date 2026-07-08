# API Design

## Overview

TempoStatusBarApp integrates with the **Tempo Server / Data Center** REST API (endpoint path `rest/tempo-timesheets/3/...`), not the newer Tempo Cloud API. This is important context when adding features or debugging — the endpoint paths and authentication model differ between Tempo Cloud and Tempo Server.

## Authentication

All requests use a Bearer token in the `Authorization` header:

```
Authorization: Bearer <apiToken>
Content-Type: application/json
```

The token is a Jira Personal Access Token generated from the user's Atlassian profile.

## Endpoints

### `GET /rest/api/2/myself`

Used to resolve the user's identity from their API token.

**Request:** No query parameters.

**Response (relevant fields):**
```json
{
  "name": "bstjohn",
  "key": "bstjohn",
  "emailAddress": "user@example.com"
}
```

**Usage in app:** The `name` field (Jira Server username/login) is used as the worklog query identifier. The `UserInfo` struct maps `accountId` to `name` in its custom decoder — this is intentional; the Tempo Server API uses username, not Atlassian cloud account IDs.

**Error handling:**
- 401 → `TempoError.unauthorized`
- 403 → `TempoError.forbidden`
- Other non-200 → `TempoError.apiError(statusCode:)`
- Network failure → `TempoError.networkError`

### `GET /rest/tempo-timesheets/3/worklogs`

Fetches worklogs for a given user within a date range.

**Query parameters:**

| Parameter | Value |
|---|---|
| `username` | Jira username (from `/myself` or user-supplied account ID) |
| `dateFrom` | 60 days before today (`yyyy-MM-dd`) |
| `dateTo` | Today (`yyyy-MM-dd`) |

**Example URL:**
```
https://yourcompany.atlassian.net/rest/tempo-timesheets/3/worklogs?username=bstjohn&dateFrom=2024-11-08&dateTo=2025-01-08
```

**Response format:** The API may return either a top-level array or a wrapped object. `TempoService.fetchWorklog(_:_:identifier:)` handles both:

```swift
// Try 1: direct array
let worklogs = try JSONDecoder().decode([Worklog].self, from: data)

// Try 2: wrapped in { "results": [...] }
let response = try JSONDecoder().decode(WorklogResponse.self, from: data)
```

**Worklog model:**
```swift
struct Worklog: Codable {
    let dateStarted: String   // "yyyy-MM-dd'T'HH:mm:ss.SSS"
    let timeSpentSeconds: Int
    let comment: String?
    let issue: WorklogIssue?  // { key: "PROJ-123", summary: "..." }
}
```

**Date parsing:** `Worklog.parseDate(_:)` tries `ISO8601DateFormatter` (with `.withInternetDateTime` and `.withFractionalSeconds`) first, then falls back to a legacy `DateFormatter` with format `yyyy-MM-dd'T'HH:mm:ss.SSS`. This handles both ISO 8601 with timezone and the bare millisecond format returned by some Tempo Server versions.

**Most-recent selection:** `getMostRecentWorklog(_:)` returns the worklog with the latest `dateStarted` using `Worklog.parseDate` for comparison.

**Error handling:** Same HTTP status mapping as `/myself`. All non-`TempoError` exceptions from the network call are wrapped as `TempoError.networkError`.

## User Identifier Resolution

The identifier used for the worklog query is resolved in `TempoService.fetchLatestWorklog`:

1. **If `accountId` is provided and non-empty** — used directly as the `username` query parameter; the `/myself` call is skipped entirely (performance optimization)
2. **Otherwise** — `/myself` is called; `userInfo.name` is used, falling back to `userInfo.key`
3. If all sources are empty → `TempoError.missingCredentials`

This means `accountId` in the credentials is really a Jira username override, not an Atlassian cloud account ID. Providing it avoids a round-trip on every refresh.

## Error Types

```swift
enum TempoError: Error, LocalizedError {
    case missingCredentials   // No usable identifier
    case invalidURL           // Malformed jiraURL
    case unauthorized         // HTTP 401
    case forbidden            // HTTP 403
    case networkError         // URLSession failure or unexpected response type
    case apiError(statusCode: Int)  // Any other non-200
}
```

`AppDelegate.updateStatusBarDisplay()` maps specific error message strings to user-friendly tooltips:
- "Unauthorized" → bad API token
- "Forbidden" → permissions issue
- "not found" → bad Account ID
- "Network" → connectivity

## Adding New API Calls

1. Add the method to `TempoService` (the concrete class).
2. Add the method signature to `TempoServiceProtocol` if it needs to be called from `WorklogStateManager` (required for testability).
3. Follow the existing pattern: construct URL from `jiraURL`, add Bearer auth header, handle HTTP status codes explicitly before attempting `JSONDecoder`.
4. Wrap all non-`TempoError` errors as `TempoError.networkError` at the catch boundary.
