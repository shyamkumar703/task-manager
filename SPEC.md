## task manager
we are going to build a task manager of sorts. here's the overview.

there will be a "master" agent that spawns to start. it's job will be to monitor things, spawn child agents for workflows as necessary, and pass new information to already running child agents.

when i'm working, there is a constant stream of incoming information that requires triage, investigation, incorporation into existing work, or a new workstream. our program is going to automate all of this.

for example, someone might tag me on slack (or DM me) asking me to do something, investigate something, etc. or someone might comment on a pr I have open on github which will require us to either amend a workstream that's already going
(if we're still working on it), or we might need to create a new git worktree and check out the branch in question to address the comment, investigate the comment, etc. or someone might say something in slack regarding a workstream that's
already active, and the parent agent will need to notify the ongoing child agent.

so in essence, this is the high-level architecture:

parent agent:
- either polls or retrieves information from a number of sources (slack, github, linear, etc.)
- depending on the information, either creates a new child agent with a goal, sends the information to an ongoing task, or simply discards the information as not useful to anything we're working on
- creates a transaction log somewhere (in an in-memory sqlite db probably) that records what happened
- notifies the user that a child agent has a questino and passes along the answer
    - this SHOULD NOT block though, the parent agent should still be able to loop along while the user is also kept aware of what is happening wiht the child agent

child agent:
- creates a new git worktree in the repo if we need to check out some code
- creates a new branch if we're building a feature
- loops until the investigation is finished or the issue is solved
- completes explicit user requests end-to-end: a request such as 'can you push the changes?' authorizes that normal push without another approval prompt; publishing is not implied by an implementation-only request
- verifies the actual result and notifies the parent agent of completion; PR status is checked through live GitHub reads rather than inferred only from local code
- if it needs user input for anything, notify the parent agent and wait for user info

other stuff:
we should have some kind of integrations system (for things like slack, github, etc.). the user should be able to specify in some kind of langague how to interact with integartions, the api keys, how often to poll, etc etc
so adding new integrations is easy.


open questions:
- how to notify the user that the child agent has a question
- how to pass the answer to the child agent
- how to show the user what is going on (is there going to be a dashboard of some sort)?
    - the user should still be able to drive the child agents manually if they want
