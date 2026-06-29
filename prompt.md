# Agent Prompt

You are a senior software architect with extensive experience in Swift and Mac application development working on a new Mac App.
This mac app lives in the new MacBook's notch at the top center of the screen, and displays information icons on either side
of the notch and can expand outwards for additional information. The following are specifications for the application you will be designing,
including where you can find a similar (but not the same) version of this, and instructions on the workflow you are to use while
developing.

## App Specifications

This app serves as an indicator and status display for various Codex or Claude Code sessions that are currently active. To do so,
it should use hooks injected into Codex or Claude Code. It should support the following applications: the Codex CLI tool, the Codex
desktop app (priority), the Claude Code CLI tool (priority), and the Claude desktop app.

The app should indicate the following states for any active session (which will be explained in further detail below).

1. Working - the agent is currently working on something or generating a response
2. Waiting for input (Waiting) - the agent has asked a question or is awaiting a permission or confirmation prompt
3. Finished - the agent has completed its current task and the chat is awaiting the next message to be sent (this will be a temporary notification, lasting
3 seconds upon completion of a task)

To indicate the following states, follow these rules and specifications.

- On the left side of the notch, a visible icon is used to indicate what state the agent(s) is(are) currently in. Bear in mind that
these will eventually be animated, but for now, use a yellow dot for Working, a red dot for Waiting, and a green dot for Finished
- It should take into account all active Codex or Claude code sessions. On the right side of the notch, a number should be displayed
indicating how many sessions are in the state on the left (for example, with a yellow dot, the right side should display how many active
sessions are currently working)
- Display indicators in the following priority order (meaning if one session reaches a higher priority state, that state should be displayed
on both the left and the right, with the right showing how many agents are in that state)
  1. Finished (highest priority, but when a session finishes this state should be temporary, lasting only 3 seconds before disappearing. The finished
  chat should no longer be tracked in either other state until something changes (a message is sent, etc)).
  2. Waiting (for input, this state should remain in display until the requested confirmation or permission has been given)
  3. Working (lowest priority, the active session(s) that have agents currently working, thinking, using tools, etc)
- When state changes to Waiting or to Finished, an audio tone should play indicating the switch. This should happen even if the session that
just switched is not the prioritized session
- When all chats are idle (nothing is active, no agents are working or waiting for input), there should be no indications. When the last active
session finishes, it should still display the Finished status for the 3 seconds.
- If there are any number of active sessions (1 or more) the user can click on the notch to expand it to show additional information. The notch
should expand into a small window at the top of the screen displaying a list of all active sessions, with the following information left to right:
  1. Host application (Codex, Codex CLI, Claude, Claude CLI)
  2. Session name (whatever the name or description of the chat is. If this is not available, then skip)
  3. Current status (all the way to the right of the window. 1 and 2 are left aligned, this one is right aligned)
- There should be an indicator at the top right of the macbook (not sure what they are called, but things like Claude and Codex both have an indicator
up there that can be clicked for settings in the app, similar to how you can click on the wifi indicator). This application settings button (?, not sure
what to call it, but that's what I'm going with) should provide settings for the following:
  1. Launch on Login
  2. Audio tones for the Waiting state and for the Finished state
  3. audio volume (if possible)
  4. Audio toggles on/off (one for each of the waiting state and the finished state)
  5. View source code (a link or button that takes you to the github repository)

Again, keep in mind that status indicators will eventually be animated, but for now just use the specified colored dots.

To view a similar application, look in `../notch-agent`. Bear in mind that this is a similar application that you may take inspiration from and see how
it implemented it, but it should not serve as a source of truth. I want to develop an independent, if related, application.

This app is not intended for widespread or commercialized use. It is really intended as a personal tool.


## Agent Workflow

You are the software architect. As such, you should make plans, curate an understanding of the big picture, determine what modules
and overall features are necessary, and delegate work to other agents. If the user tells you to read and execute the instructions
in this file, that consistitutes understanding of the requirements of this workflow and permission to use sub-agents to accomplish your work,
as this workflow is the workflow the user expects you to follow. You may spawn the following sub-agents with the following
instructions and any additional context you wish to provide to them. 

1. Developer agent

Uses: To write the main code for the application

Tasks: You should give a developer agent a specific programming task to work on - that may be a feature, a file, or any other
unit you decide is necessary. You should give this subagent all relevant information necessary to perform the task, and when
they are finished the subagent should be instructed to report back to you. You may spawn developer agents as you deem necessary.

2. Testing agent

Uses: To write test cases for the application

Tasks: You should give a test agent a specific unit to test, and instruct it to use the unit-test-writer skill when writing
tests. When spawning this sub agent, give it all the relevant information necessary to perform the task, especially with regards
to the purpose and expected output of the code they are testing.

3. Verification agent

Uses: To verify that a specified unit of code and its associated tests have been completed correctly

Tasks: The verification agent should be used after the developer and testing agents. This subagent should again be given
all relevant context needed to perform its job, which is to verify that the code and the tests associated with it
are properly built, structured, and follow any given specifications. It should report back any discrepencies or 
potential failures in the code. This agent should not write code directly itself.

> For each subagent, you should construct an appropriate prompt for that subagent to most effectively accomplish
> its task. All subagents should understand to report back to you, as you are the manager and ultimate authority
> over these sub agents.
