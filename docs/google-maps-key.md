<p align="right"><b>English</b> · <a href="google-maps-key.ko.md">한국어</a></p>

# Using your own Google Maps key

Afterplate finds the places around a meal's photos with Google Places. By default every Mac gets a weekly share of Afterplate's own searches, about fifteen visits, refilled every Monday (UTC). That is enough for the first launch and ordinary use. When a week's share is spent, the visits wait for next week.

If you would rather not wait, put your own key in **Settings → Place search**. Places are then searched on your key, within the free calls Google gives every project each month.

## Getting a key (about ten minutes)

1. **Create a project**: [console.cloud.google.com/projectcreate](https://console.cloud.google.com/projectcreate)
2. **Link a billing account**: [console.cloud.google.com/billing](https://console.cloud.google.com/billing). Google asks for a card even for the free calls. Nothing is charged while you stay within them.
3. **Enable Places API (New)**: [console.cloud.google.com/apis/library/places.googleapis.com](https://console.cloud.google.com/apis/library/places.googleapis.com)
4. **Create the key**: [console.cloud.google.com/apis/credentials](https://console.cloud.google.com/apis/credentials) → *Create credentials* → *API key*. Under *API restrictions*, allow only **Places API (New)**.
5. **Optional, recommended: cap it.** On [the quotas page](https://console.cloud.google.com/apis/api/places.googleapis.com/quotas), set *SearchNearby requests per day* to about 150 (and *SearchText* the same). Then a bug can never take you past the free calls.
6. Paste the key into **Settings → Place search → Your Google Maps key** and press *Save*. The key is kept in the macOS Keychain.

## What the app asks Google

| Call | When | Google's tier |
|---|---|---|
| Nearby Search | once per visit, twice in a dense block | Pro |
| Nearby Search with reviews | when the kinds of place alone can't tell two nearby candidates apart | Enterprise |
| Text Search | when you search a place by name | Pro |
| Place Details (location only) | to put a chosen place on the map | Essentials |

At Google's free monthly counts as of October 2026 (Pro 5,000, Enterprise 1,000, Essentials 10,000 calls), one key covers about 2,500 visits a month.

Remove the key in Settings to go back to Afterplate's share.
