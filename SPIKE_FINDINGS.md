# Spike: Gemini CLI / Antigravity OAuth Credential File Discovery

## Summary

Confirmed OAuth credential storage locations and structures for `gemini-cli` and `antigravity` CLIs. Neither provider caches the Google Cloud project ID locally — both require runtime API calls to `loadCodeAssist` to resolve it.

## Findings

### 1. Gemini CLI Credentials

**File Path:** `~/.gemini/oauth_creds.json`

**Key Structure (redacted):**
```json
{
  "access_token": "<str len=260>",
  "refresh_token": "<str len=103>",
  "id_token": "<str len=1141>",
  "expiry_date": 1782250684420,
  "scope": "<str len=149>",
  "token_type": "<str len=6>"
}
```

**Notes:**
- Credentials are stored in JSON format
- Access token is approximately 260 characters
- Refresh token is approximately 103 characters
- Expiry is stored as a Unix timestamp in milliseconds
- ID token included for identity validation
- **Project ID is NOT cached locally**

### 2. Antigravity Credentials

**Finding:** Antigravity does NOT have a dedicated OAuth credential file in `~/.antigravity/` or `~/.gemini/antigravity/`.

**Likely Storage:**
- Antigravity may share the `~/.gemini/oauth_creds.json` file with gemini-cli (both are Google products with unified Google OAuth infrastructure)
- Alternatively, it may use Google Cloud's Application Default Credentials (ADC) mechanism, which checks:
  1. `GOOGLE_APPLICATION_CREDENTIALS` environment variable
  2. `~/.config/gcloud/application_default_credentials.json` (gcloud credentials)
  3. Metadata server credentials (if running on GCP)

**Directory Structure:** `~/.gemini/` contains subdirectories `antigravity/` and `antigravity-cli/` which hold settings (`.pb` Protocol Buffer files, JSON configs, history, etc.), but no OAuth tokens.

**Project ID:** NOT cached locally

### 3. Project ID Resolution

**For Both Providers:**

Both `gemini-cli` and `antigravity` require a Google Cloud project ID to query quota usage via the `retrieveUserQuota` / `fetchAvailableModels` APIs.

**Resolution Strategy (from 9router `open-sse/services/usage/google.js`):**

1. First, check if `projectId` is already stored in `providerSpecificData` (passed at runtime, not from local files)
2. If not found, make an API call to `loadCodeAssist` endpoint:
   - **Gemini CLI:** `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
   - **Antigravity:** `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` (same endpoint)
3. API call returns `cloudaicompanionProject` field containing the project ID
4. Call returns subscription info including `currentTier.name` (for plan display)

**Example API Request (both providers):**
```json
{
  "metadata": {
    "user_agent": "...",
    "client_version": "..."
  }
}
```

**No local cache needed** — the API call is lightweight (~100ms) and can be done on demand when quota is first requested.

## Comparison to Other Providers

| Provider | Credentials File | Token Field | Project ID Cached? |
|----------|---|---|---|
| Claude (`claude-cli`) | `~/.claude/.credentials.json` | `claudeAiOauth.accessToken` | No |
| Codex | `~/.codex/auth.json` | `tokens.access_token` | No |
| Gemini CLI | `~/.gemini/oauth_creds.json` | `access_token` | **No** |
| Antigravity | (shared? or ADC) | (shared? or ADC) | **No** |

## Recommendations for Arbiter Integration

1. **Load Strategy:**
   - Load gemini-cli credentials from `~/.gemini/oauth_creds.json` → `access_token`
   - For antigravity, first attempt to load from same path; if not found, fall back to Google Cloud ADC

2. **Project ID Handling:**
   - Do NOT try to cache/discover project ID locally
   - Make the `loadCodeAssist` API call on demand (when quota is requested)
   - Response includes both project ID and current tier, so it's a unified call

3. **Token Refresh:**
   - Both providers use standard OAuth 2.0 with refresh tokens
   - Use `https://oauth2.googleapis.com/token` endpoint for refresh (public client flow)

4. **Next Steps:**
   - Implement 9router-style usage fetching for both providers
   - Start with Gemini CLI (fully confirmed file path)
   - Validate Antigravity credential loading on this machine (may need to check ADC fallback)

## Unresolved

- Whether `antigravity` can actually share `~/.gemini/oauth_creds.json` or requires separate authentication
  - Antigraivity installed on this system is a GUI IDE (`/usr/bin/antigravity` → `/usr/share/antigravity/bin/antigravity`)
  - Only available method to confirm is to attempt a real API call with shared credentials
- Exact format of `user_settings.pb` in `~/.gemini/antigravity/` (Protocol Buffer binary, not inspectable without schema)

