# ModSmith results and next steps

ModSmith's workflow applies to every generated mod. A reported website or mod
is a reproduction case, not a reason to add a special action to the product.

The result envelope uses `active` only for verified requested behavior.
`needs_help` includes a structured next step:

```json
{
  "status": "needs_help",
  "summary": "The layout is saved. Choose the style to finish.",
  "next_step": {
    "title": "Choose a reading style",
    "detail": "Would you prefer a warm background or the original colors?",
    "action": "reply"
  }
}
```

`reply` focuses the composer for an answer. `resume` is for a prerequisite the
owner can complete outside the conversation; the UI asks the owner to confirm
completion before resuming. These are presentation choices, not executable
commands or permission grants. Titles are limited to 100 characters and details
to 1,500. Valid `blocker` objects provide a fallback when a next step is missing.
Results without either offer clarification instead of guessing the required input.

Enable, resume, retry, and clarify actions keep their instructions in agent
context and durable history. UI snapshots expose only short activity messages;
Undo uses the same short labels. Previously saved enable/resume instructions
are presented this way as well. Owner-written requests remain visible.

Security-review failures produce a separate repair notice even when the final
result also asks for input. A later approved revision for the same file clears
that run's review failure. Enabling a mod does not establish verification.
Testing respects existing authorization and asks for additional choices or
permissions only when needed, regardless of the mod's website or behavior.

Open a mod from the **ModSmith sidebar**, then choose **Delete mod**, or use **Delete…**
in **Settings → Mods**. Both paths ask for confirmation and use the same cleanup. Confirmation removes
its active and disabled files, assets, and the entire ModSmith project (requests,
agent session reference, conversation, and undo revisions). Empty or failed
projects can also be deleted. Deletion is unavailable during a build, respects
profile and saved-app ownership, and refuses to delete files referenced by
a different mod project. Duplicate histories referring to the same set of mod
files (including enabled/disabled aliases) are removed together. A failed history save restores removed files. Existing runtime
watchers unload deleted mods. Website actions and persistent mod data are not
reversed or erased.

Each mod has a stable `mod_id` and an explicit `owned_files` list, independent
of its conversation and undo records. Editing from Settings or the ModSmith sidebar returns
to that mod’s conversation. Creation cannot overwrite files owned by another
mod; open the existing mod to refine it. On workspace load, duplicate histories
with the same file set and profile/app owner are combined, preserving messages,
undo revisions and assets, and redirecting selections to the retained mod.
Enabled and disabled filenames refer to the same file identity. Empty drafts
and different profile/app owners remain separate.

ModSmith assumes informed, legitimate owner intent for ordinary customization
requests. It investigates implementations and reports observed technical blockers,
not speculative copyright, licensing or service-authorization prerequisites.
Missing user input must be necessary for a specific action; actual tool/security
boundaries still apply. Resumed conversations reassess unsupported earlier blockers.

A page-payload limitation triggers investigation of the Elixir mod tier. Site
scope restricts target pages, not the mod to JavaScript. Media processing and
multi-request integrations are not automatic handoffs. ModSmith tries feasible
alternatives, repairs failures, and prefers self-contained mods or verified local
capabilities over asking the owner to deploy a service. Dependency claims require
evidence; new installations or consequential actions still need appropriate
owner authorization. Generated native work remains subject to the code audit.

Installed mod results include `usage`: `entry_point` identifies the exact control,
command, shortcut or automatic trigger; `steps` contains ordered instructions;
`tips` covers relevant configuration and limitations. Guides describe implemented
behavior, refresh after changes, and appear above the conversation in **How to
use**. The UI supplies management directions. Guides stay with the mod and Undo
restores the guide captured before that revision.

**Generate instructions** and **Update instructions** inspect existing source
and page HTML without changing or executing the mod. The tool gateway restricts
these runs to read tools, and completion preserves the mod’s prior status and
undo revisions. Missing or malformed guide output shows a retryable error.

ModSmith’s sidebar lists saved mod conversations across sessions, with the current
selection highlighted. Select a mod to reopen its full chat and guide; subsequent
changes append to that conversation. Installed mods without a chat can be opened
from the same list. Drafts remain visible as drafts. Profile and saved-app
boundaries continue to filter which conversations appear. Unsent text is retained
when switching conversations in the open window.

When a target tab leaves the mod’s site, ModSmith recovers to another matching tab in the same profile. Tab discovery, mod discovery, source reads and diagnostics remain available when no matching tab is open. Page actions and draft writes wait for a matching tab; discovery reports the current URLs and whether a target is available.

Before calling a result working, ModSmith runs a separate, tool-free outcome review against the original request, later changes and actual tool receipts. The proposed files must already be installed, and the reviewer must cite live observations after the last draft write. Compilation, a visible button or disabling a failed action alone does not establish success. The review can send the generator back for up to two repair attempts; unavailable or inconclusive reviews leave the result unverified. This is model-assisted evidence review, not a guarantee of correctness.

Failed review findings stay with the mod independently of the recent chat window. Refinements use them to investigate different implementations, including maintained local libraries or tools through an audited native mod when appropriate. The review does not bypass the code security audit or grant permission for external actions. Raw tool transcripts remain bounded in run memory; the retained history contains concise review findings.

`page_screenshot(webview: id, max_width: 1280)` returns a PNG image of the loaded webpage viewport directly from WebKit, without desktop screen-recording permission. `list_tabs` supplies tab IDs; ModSmith pins the target to its scoped tab, and saved apps capture only their own page. Deferred tabs must be activated first. `max_width` bounds the longest image edge to 320–1920 pixels; `point_width`, `point_height` and `scale` map image pixels to viewport points. The tool excludes browser chrome and does not capture the full document; WebKit may omit protected video.

MCP returns image content alongside capture metadata. Direct API generation receives screenshots as multimodal input, and its outcome reviewer can cite the latest two post-change images. CLI generation receives MCP images too; the tool-free CLI outcome review requires DOM/runtime evidence rather than screenshot-only evidence. The separate `native_screenshot` tool captures native browser chrome through macOS and still needs screen-capture permission.
