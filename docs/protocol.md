# Helper JSON protocol

The Swift app sends the .NET Helper one UTF-8 JSON object per line on stdin.
The Helper writes responses on stdout and diagnostics on stderr. Terminate each
request with a newline. The Swift client sends one request at a time and waits
for its response, except when exiting.

Requests have an integer `id`, a lowercase `command`, and the fields listed
below. Responses echo the request's `id` and set `ok` to a boolean. Successful
`open` and `new` responses include `result`, and failures include an `error`
string. Absent values are omitted. Invalid JSON returns an error with `id: 0`.
Empty lines and JSON `null` are ignored.

The records in [Helper/Program.cs](../Helper/Program.cs) define the wire fields
for tasks, dependencies, resources, assignments, calendars, and exceptions.
The Swift counterparts are in [Models.swift](../App/Sources/MPPViewerMac/Models.swift).

## Opening an existing project

`open` takes a nonblank `path` and loads a project into the Helper's current
session. The result contains its title, visible tasks, resources, budget, and
calendars. The example shows a project with empty task, resource, and calendar
lists.

**Request**

```json
{"id":1,"command":"open","path":"example.mpp"}
```

**Response**

```json
{"id":1,"ok":true,"result":{"title":"Example","tasks":[],"resources":[],"budgetCost":0,"calendars":[]}}
```

## Starting a project

`new` takes only the request envelope and starts an empty project in memory.
Its result has the same shape as `open`. The app may add a starter task locally
after it receives that result.

**Request**

```json
{"id":2,"command":"new"}
```

**Response**

```json
{"id":2,"ok":true,"result":{"title":"Untitled Project","tasks":[],"resources":[],"budgetCost":0,"calendars":[]}}
```

## Saving the current project

`save` writes Microsoft Project XML (MSPDI) to a nonblank `path`. Run `open`
or `new` in the same Helper process first. The Helper edits the live MPXJ
project so retained tasks and resources can keep data outside the editable DTOs,
such as custom fields and baselines.

| Field | Behavior |
| --- | --- |
| `path`, `tasks` | Required. Send the XML destination and the complete current task array. |
| `resources` | Send the complete current resource array. Omission is equivalent to an empty array. |
| `budgetCost` | Optional numeric budget. Defaults to zero. |
| `calendars` | Optional array. Omit it to keep the current calendars, or supply the desired list to synchronize them. |
| `title` | Optional. A nonblank value sets the title and resets author and other identity metadata. |

The example saves the empty project from `new`.

**Request**

```json
{"id":3,"command":"save","path":"example.xml","tasks":[],"resources":[],"budgetCost":0}
```

**Response**

```json
{"id":3,"ok":true}
```

A valid save request before the session has a project returns
`{"id":3,"ok":false,"error":"No project is open."}`.

## Closing the Helper

`exit` takes only the request envelope. The Helper exits with status zero and
sends no response line. The Swift client sends this message and waits for the
process to exit. Closing stdin also ends the process.

**Request**

```json
{"id":0,"command":"exit"}
```
