# Channel Pinning and Ordering

This document describes how admins can pin channels and control their display order within a group using the `extra` metadata fields in channel metadata.

## Overview

Admins can control channel visibility and ordering by setting special fields in the `extra` object of channel metadata:

- **`pinned`**: Boolean flag to pin a channel (show it at the top)
- **`order`**: Numeric value to control channel ordering (lower numbers appear first)

These fields are **admin-only** - only group admins can set or modify them. Regular members can update other channel metadata (name, about, picture, etc.) but cannot modify `pinned` or `order`.

## Metadata Structure

Channel metadata is stored in relay-signed `kind 39004` events. The `extra` object contains application-specific fields:

```json
{
  "id": "<channel_id>",
  "group_id": "<group_id>",
  "name": "General",
  "about": "General discussion",
  "picture": "https://example.com/general.png",
  "relays": ["wss://relay.example"],
  "creator": "<pubkey>",
  "extra": {
    "pinned": true,
    "order": 1
  }
}
```

## Admin-Only Fields

### `pinned` (boolean)

- **Purpose**: Mark a channel as pinned (typically displayed at the top of the channel list)
- **Values**: `true` or `false`
- **Default**: If not set, the channel is not pinned
- **Permission**: Admin-only

### `order` (number)

- **Purpose**: Control the display order of channels
- **Values**: Any numeric value (integers or floats)
- **Sorting**: Lower numbers appear first
- **Default**: If not set, channels are typically sorted by creation time or name
- **Permission**: Admin-only

## Usage

### Pinning a Channel

To pin a channel, an admin sends a `kind 41` (channel metadata) event with the `pinned` field in `extra`:

```json
{
  "kind": 41,
  "content": "{\"extra\":{\"pinned\":true}}",
  "tags": [
    ["h", "<group_id>"],
    ["e", "<channel_id>"]
  ]
}
```

### Setting Channel Order

To set a channel's display order, an admin includes the `order` field in `extra`:

```json
{
  "kind": 41,
  "content": "{\"extra\":{\"order\":1}}",
  "tags": [
    ["h", "<group_id>"],
    ["e", "<channel_id>"]
  ]
}
```

### Combining Pinned and Order

You can set both fields together:

```json
{
  "kind": 41,
  "content": "{\"extra\":{\"pinned\":true,\"order\":1}}",
  "tags": [
    ["h", "<group_id>"],
    ["e", "<channel_id>"]
  ]
}
```

### Unpinning a Channel

To unpin a channel, set `pinned` to `false` or remove it:

```json
{
  "kind": 41,
  "content": "{\"extra\":{\"pinned\":false}}",
  "tags": [
    ["h", "<group_id>"],
    ["e", "<channel_id>"]
  ]
}
```

## Permission Enforcement

The relay enforces admin-only access to `pinned` and `order` fields:

- **Admins**: Can set, modify, or remove `pinned` and `order` fields
- **Members**: Cannot modify `pinned` or `order` fields
  - Attempting to set these fields as a non-admin will result in rejection: `"only admins can set pinned or order fields"`
  - Members can still update other metadata fields (name, about, picture, relays)

## Field Merging

When updating channel metadata, the `extra` object is merged with existing values:

- **New fields**: Added to the existing `extra` object
- **Existing fields**: Overwritten with new values
- **Other fields**: Preserved if not specified in the update

Example: If a channel has `extra: {archived: false, order: 5}` and you update with `extra: {pinned: true}`, the result is `extra: {archived: false, order: 5, pinned: true}`.

## Client Implementation

### Querying Channels

Clients query channel metadata using `kind 39004` events:

```json
{
  "kinds": [39004],
  "#h": ["<group_id>"]
}
```

### Sorting Channels

Clients should sort channels as follows:

1. **Pinned channels first**: Channels with `extra.pinned === true` appear at the top
2. **Order by `order` field**: Within pinned and unpinned groups, sort by `extra.order` (ascending)
3. **Fallback sorting**: For channels without `order`, use creation time or name

Example sorting logic:

```javascript
channels.sort((a, b) => {
  // Pinned channels first
  const aPinned = a.extra?.pinned === true;
  const bPinned = b.extra?.pinned === true;
  if (aPinned !== bPinned) {
    return aPinned ? -1 : 1;
  }
  
  // Then by order (if available)
  const aOrder = a.extra?.order ?? Infinity;
  const bOrder = b.extra?.order ?? Infinity;
  if (aOrder !== bOrder) {
    return aOrder - bOrder;
  }
  
  // Fallback to creation time or name
  return a.created_at - b.created_at;
});
```

### Display Recommendations

- **Pinned channels**: Display with a pin icon or in a separate "Pinned" section
- **Ordered channels**: Respect the `order` value for consistent display across clients
- **Unordered channels**: Display in a predictable order (e.g., by creation time or alphabetically)

## Examples

### Example 1: Pin Important Channels

An admin wants to pin the "Announcements" and "Rules" channels:

```json
// Pin Announcements channel
{
  "kind": 41,
  "content": "{\"extra\":{\"pinned\":true,\"order\":1}}",
  "tags": [
    ["h", "my-group"],
    ["e", "announcements-channel-id"]
  ]
}

// Pin Rules channel
{
  "kind": 41,
  "content": "{\"extra\":{\"pinned\":true,\"order\":2}}",
  "tags": [
    ["h", "my-group"],
    ["e", "rules-channel-id"]
  ]
}
```

### Example 2: Custom Channel Ordering

An admin wants to organize channels in a specific order:

```json
// General channel - order 1
{
  "kind": 41,
  "content": "{\"extra\":{\"order\":1}}",
  "tags": [
    ["h", "my-group"],
    ["e", "general-channel-id"]
  ]
}

// Support channel - order 2
{
  "kind": 41,
  "content": "{\"extra\":{\"order\":2}}",
  "tags": [
    ["h", "my-group"],
    ["e", "support-channel-id"]
  ]
}

// Off-topic channel - order 10 (appears later)
{
  "kind": 41,
  "content": "{\"extra\":{\"order\":10}}",
  "tags": [
    ["h", "my-group"],
    ["e", "offtopic-channel-id"]
  ]
}
```

### Example 3: Member Attempting to Pin (Will Fail)

A non-admin member tries to pin a channel:

```json
{
  "kind": 41,
  "content": "{\"extra\":{\"pinned\":true}}",
  "tags": [
    ["h", "my-group"],
    ["e", "some-channel-id"]
  ]
}
```

**Result**: Event is rejected with: `"only admins can set pinned or order fields"`

## Related Documentation

- [Per-Channel Relay Metadata for Group Channels](./group-channels-per-channel-metadata.md) - Overview of the per-channel metadata system
- [NIP-28](https://github.com/nostr-protocol/nips/blob/master/28.md) - Public Chat specification
- [NIP-29](https://github.com/nostr-protocol/nips/blob/master/29.md) - Relay-based Groups specification
