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

Open a mod from **Your mods**, then choose **Delete mod**. Confirmation removes
its active and disabled files, assets, and the entire ModSmith project (requests,
agent session reference, conversation, and undo revisions). Empty or failed
projects can also be deleted. Deletion is unavailable during a build, respects
profile and saved-app ownership, and refuses to delete files referenced by
another project. A failed history save restores removed files. Existing runtime
watchers unload deleted mods. Website actions and persistent mod data are not
reversed or erased.
