#!/usr/bin/env bash


If you'd like to read these release notes online, go to Updates on code.visualstudio.com.

Insiders: Want to try new features as soon as possible?
You can download the nightly Insiders build and try the latest updates as soon as they are available.
Download Insiders

In this update
Autopilot and agent permissions
Agent-scoped hooks (Preview)
Debug events snapshot
Chat tip improvements
AI CLI profile group in terminal dropdown (Experimental)
Extension authoring
Engineering
Deprecated features and settings
Notable fixes
Thank you
Autopilot and agent permissions
Setting:   chat.autopilot.enabled

The new permissions picker in the Chat view lets you control how much autonomy the agent has. The permission level applies only to the current session. You can change it at any time during a session by selecting a different level from the permissions picker.

You can choose from the following permission levels:

Permission level	Description
Default Approvals	Uses your configured approval settings. Tools that require approval show a confirmation dialog before they run.
Bypass Approvals	Auto-approves all tool calls without showing confirmation dialogs and automatically retries on errors.
Autopilot (Preview)	Auto-approves all tool calls, automatically retries on errors, auto-responds to questions, and the agent continues working autonomously until the task is complete.
Screenshot showing the permissions picker in the Chat view with Default Approvals, Bypass Approvals, and Autopilot options.

Autopilot (Preview)
Autopilot is enabled by default in Insiders. You can activate it in Stable by enabling   chat.autopilot.enabled .

Behind the scenes, the agent stays in control and iterates until it signals completion by calling the task_complete tool.

Note: Bypass Approvals and Autopilot bypass manual approval prompts and ignore your configured approval settings, including for potentially destructive actions like file edits, terminal commands, and external tool calls. The first time you enable either level, a warning dialog asks you to confirm. Only use these levels if you understand the security implications.

Learn more about Autopilot and agent permissions in our documentation.

Agent scoped hooks (Preview)
Setting:   chat.useCustomAgentHooks

Custom agent frontmatter now supports agent-scoped hooks that are only run when you select the specific agent or when it's invoked via runSubagent. This lets you attach pre- and post-processing logic to specific agents without affecting other chat interactions.

To create an agent-scoped hook, define it in the hooks section of the YAML frontmatter of your .agent.md file.

To try this feature, enable the   chat.useCustomAgentHooks setting. For more information, see Agent-scoped hooks in our documentation.
