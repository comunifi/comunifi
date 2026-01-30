# Admin Invite Flow for NIP-29 Groups

This document describes how to implement the admin-initiated invite flow for NIP-29 groups, where admins can invite users directly and users can accept those invites.

---

## Overview

In closed NIP-29 groups, users typically need to send a join request (`kind:9021`) and wait for an admin to manually approve them via `kind:9000` (put-user). 

The admin invite flow provides a better UX:
1. **Admin creates an invite** (`kind:9009`) targeting a specific user
2. **User discovers the invite** by querying for invites targeting them
3. **User accepts the invite** by sending a join request (`kind:9021`)
4. **Relay auto-approves** the join request if a valid invite exists

---

## Event Kinds

### `kind:9009` - Create Invite (Admin-only)

Admins can create invites for specific users. This event must be signed by an admin of the group.

**Required Tags:**
- `h` - Group ID
- `p` - Target user pubkey (one or more `p` tags allowed)

**Optional Tags:**
- `code` - Optional invite code (for code-based invites, backward compatible)

**Example:**

```json
{
  "kind": 9009,
  "pubkey": "<admin-pubkey>",
  "content": "optional reason or message",
  "tags": [
    ["h", "group-abc123"],
    ["p", "target-user-pubkey-hex"]
  ],
  "created_at": 1234567890
}
```

**Validation:**
- Event author must be an admin of the group
- `h` tag (group ID) must be present
- At least one `p` tag (target user) must be present

### `kind:9021` - Join Request (User)

Users send this to request joining a group. If a valid invite exists, the relay will automatically approve it.

**Required Tags:**
- `h` - Group ID

**Optional Tags:**
- `e` - Reference to specific invite event ID (optional, relay will match by group ID and user pubkey if not provided)
- `code` - Optional invite code (if using code-based invites)

**Example:**

```json
{
  "kind": 9021,
  "pubkey": "<user-pubkey>",
  "content": "optional reason",
  "tags": [
    ["h", "group-abc123"],
    ["e", "<invite-event-id>"]  // optional
  ],
  "created_at": 1234567890
}
```

**Auto-approval:**
- If a valid `kind:9009` invite exists for this user in this group, the relay automatically generates a `kind:9000` (put-user) event
- The user becomes a member immediately
- If no invite exists, the request is stored for manual admin review

---

## Client Implementation Guide

### 1. Admin: Creating an Invite

To invite a user to a group:

```javascript
// Create invite event
const inviteEvent = {
  kind: 9009,
  pubkey: adminPubkey,
  content: "You're invited to join our group!",
  tags: [
    ["h", groupID],
    ["p", targetUserPubkey]
  ],
  created_at: Math.floor(Date.now() / 1000)
}

// Sign and publish
const signedEvent = await signEvent(inviteEvent)
await relay.publish(signedEvent)
```

**Multiple users:** You can include multiple `p` tags to invite multiple users at once:

```javascript
tags: [
  ["h", groupID],
  ["p", "user1-pubkey"],
  ["p", "user2-pubkey"],
  ["p", "user3-pubkey"]
]
```

### 2. User: Discovering Pending Invites

Users can query for invites targeting them:

```javascript
// Query for invites where user's pubkey is in a p tag
const inviteFilter = {
  kinds: [9009],
  "#p": [userPubkey],
  limit: 100
}

const invites = await relay.query(inviteFilter)

// Display invites to user
for (const invite of invites) {
  const groupID = invite.tags.find(t => t[0] === 'h')?.[1]
  const inviterPubkey = invite.pubkey
  console.log(`Invited to group ${groupID} by ${inviterPubkey}`)
}
```

**Filtering by group:** To get invites for a specific group:

```javascript
const inviteFilter = {
  kinds: [9009],
  "#h": [groupID],
  "#p": [userPubkey],
  limit: 100
}
```

### 3. User: Accepting an Invite

When a user wants to accept an invite:

```javascript
// Create join request
const joinRequest = {
  kind: 9021,
  pubkey: userPubkey,
  content: "Accepting invite",
  tags: [
    ["h", groupID],
    ["e", inviteEventID]  // optional: reference specific invite
  ],
  created_at: Math.floor(Date.now() / 1000)
}

// Sign and publish
const signedEvent = await signEvent(joinRequest)
await relay.publish(signedEvent)
```

**Note:** The `e` tag is optional. If omitted, the relay will match invites by group ID and user pubkey automatically.

### 4. Checking Membership Status

After sending a join request, check if membership was granted:

```javascript
// Wait a moment for relay to process
await sleep(1000)

// Query for put-user events (kind:9000) for this user
const membershipFilter = {
  kinds: [9000],
  "#h": [groupID],
  "#p": [userPubkey],
  limit: 1
}

const membershipEvents = await relay.query(membershipFilter)

if (membershipEvents.length > 0) {
  console.log("Successfully joined the group!")
} else {
  console.log("Join request pending admin approval...")
}
```

Alternatively, query the relay-generated members list:

```javascript
const membersFilter = {
  kinds: [39002],  // Group members list
  "#d": [groupID],
  limit: 1
}

const memberLists = await relay.query(membersFilter)
const isMember = memberLists.some(list => 
  list.tags.some(t => t[0] === 'p' && t[1] === userPubkey)
)
```

---

## Flow Diagram

```
┌─────────┐                    ┌────────┐                    ┌─────────┐
│  Admin  │                    │ Relay  │                    │  User   │
└────┬────┘                    └───┬────┘                    └────┬────┘
     │                              │                              │
     │ kind:9009 (create-invite)   │                              │
     │ h: group-id                 │                              │
     │ p: user-pubkey              │                              │
     ├─────────────────────────────>│                              │
     │                              │ Store invite event           │
     │                              │                              │
     │                              │                              │
     │                              │                              │ Query kind:9009
     │                              │                              │ #p: [user-pubkey]
     │                              │<─────────────────────────────┤
     │                              │ Return invite events         │
     │                              ├─────────────────────────────>│
     │                              │                              │
     │                              │                              │ kind:9021 (join-request)
     │                              │                              │ h: group-id
     │                              │<─────────────────────────────┤
     │                              │                              │
     │                              │ Check for matching invite    │
     │                              │                              │
     │                              │ kind:9000 (put-user)         │
     │                              │ [auto-generated by relay]     │
     │                              │                              │
     │                              │ User is now a member         │
     │                              │                              │
```

---

## Error Handling

### Invalid Invite Creation

If a non-admin tries to create an invite:

```
Error: "only admins can create invites"
```

### Join Request Without Invite

If a user sends a join request without a valid invite:

- The request is **stored** but not auto-approved
- Admins can see the request and manually approve via `kind:9000`
- The user should wait for admin approval

### Already a Member

If a user tries to join when already a member:

```
Error: "duplicate: already a member of this group"
```

### Invite Already Used

If a user tries to use an invite after already becoming a member:

- The invite is considered "used" once the user is a member
- The join request will be rejected with "duplicate: already a member"
- A new invite would be needed if the user was removed and wants to rejoin

---

## Best Practices

1. **Invite Discovery:** Periodically query for new invites to show users pending invitations
2. **UI Feedback:** Show users when their join request is auto-approved vs. pending
3. **Error Messages:** Display clear error messages when invite creation or acceptance fails
4. **Event References:** While optional, including the `e` tag in join requests can help with tracking and debugging
5. **Multiple Invites:** If multiple invites exist, the relay uses the most recent one

---

## Example: Complete Flow

```javascript
// ===== ADMIN SIDE =====

// 1. Admin creates invite
const inviteEvent = {
  kind: 9009,
  pubkey: adminPubkey,
  content: "Welcome to our group!",
  tags: [
    ["h", "my-group-123"],
    ["p", "user-pubkey-abc"]
  ],
  created_at: Math.floor(Date.now() / 1000)
}
await relay.publish(await signEvent(inviteEvent))

// ===== USER SIDE =====

// 2. User queries for invites
const invites = await relay.query({
  kinds: [9009],
  "#p": [userPubkey]
})

// 3. User finds invite for "my-group-123"
const myInvite = invites.find(inv => 
  inv.tags.find(t => t[0] === 'h')?.[1] === "my-group-123"
)

// 4. User accepts invite
const joinRequest = {
  kind: 9021,
  pubkey: userPubkey,
  content: "Thanks for the invite!",
  tags: [
    ["h", "my-group-123"],
    ["e", myInvite.id]  // reference the invite
  ],
  created_at: Math.floor(Date.now() / 1000)
}
await relay.publish(await signEvent(joinRequest))

// 5. User checks membership (after short delay)
await sleep(1000)
const isMember = await checkMembership("my-group-123", userPubkey)
console.log("Member:", isMember)  // Should be true
```

---

## Related NIPs

- [NIP-29](https://github.com/nostr-protocol/nips/blob/master/29.md) - Relay-based Groups
- [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) - Basic protocol

---

## Notes

- Invites are stored as regular events, so they're queryable and discoverable
- An invite is considered "used" once the user becomes a member
- If a user is removed from a group, they would need a new invite to rejoin
- The relay automatically generates `kind:9000` events when valid invites are used
- Code-based invites (using `code` tag) are supported for backward compatibility but not required for the direct invite flow
