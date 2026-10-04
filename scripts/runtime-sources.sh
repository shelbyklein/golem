#!/bin/bash
# Source list for the Foundation-only conversation engine, shared with the daemon.
for name in Models ChatSession ChatSession+Claude ChatSession+Codex ChatSession+Host ChatSession+Status ChatSession+Summary ChatSession+Shell ChatSession+Remote ChatSession+Tasks ChatSession+Issues ClaudeCode CodexAppServer HostClient Usage ClaudeModels SlashCommands Tools ModelPresets GitHub GitHubIssues IssuePrompts Prompts PermissionModes Secrets EasyCLIProxy CodexRoute BackgroundTasks ChatComputer; do
  printf '%s\n' "Chatterbox/Engine/$name.swift"
done
printf '%s\n' Chatterbox/Support/JSON.swift Chatterbox/Support/HostProtocol.swift Chatterbox/Support/Attachments.swift
printf '%s\n' Shared/AppPreferences.swift Shared/Backend.swift Shared/MediaKind.swift Shared/FilePaths.swift
rg --follow --files ChatterboxRuntime -g '*.swift' -g '!RuntimeClient.swift'
