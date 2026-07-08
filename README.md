# TempoStatusBarApp

This is a macOS menu bar app that shows how many days have passed since your last Jira Tempo worklog submission.

## Features
- Jira instance URL, API token & user ID input via UI
- Uses Jira Tempo REST API to fetch latest worklog
- Menu bar display updates every hour
- Color-coded status with configurable warning threshold

## API Configuration

### Jira Instance URL
- Use your full Jira instance URL (e.g., `https://yourcompany.atlassian.net`)
- Make sure to include the protocol (https://)

### API Token
- Generate an API token from your Atlassian Profile > Personal Access Tokens page

### Warning Threshold
- Configure how many days without a worklog before showing a warning
- Default is 7 days
- Three status levels:
  - Green (✅): Within threshold
  - Orange (⏰): One day over threshold
  - Red (🚨): More than one day over threshold

### API Endpoints
The app uses these Tempo API endpoints:
- User info: `/rest/api/2/myself`
- Worklogs: `/rest/tempo-timesheets/3/worklogs` with date range parameters

### Auto-detection
The app automatically:
- Fetches your user information from `/rest/api/2/myself`
- Uses your username or key as the identifier
