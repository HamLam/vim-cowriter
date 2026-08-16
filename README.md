'''
pip install google-adk
install ollama with curl: 
curl -fsSL https://ollama.com/download/ollama-linux-amd64.tar.zst \
    | sudo tar x -C /usr
pull gemma4:26b model
'''
Vim is the human's workspace, while ADK supplies the agent intelligence and tool-use layer. In the current Vim co-writer, we're using a **fairly small subset of Google ADK**. The Vim integration itself is *not* an ADK feature; Vimscript handles the editor communication, while ADK handles the agent reasoning/tool loop.

Here are the pieces we're using.

### **1\. `Agent` / `LlmAgent`**

In `adk_bridge.py` we create:

```py
root_agent = Agent(
    name="vim_cowriter",
    model=local_model,
    instruction="""...""",
    tools=[
        get_vim_buffer,
        insert_after_line,
        replace_lines,
    ],
)
```

This is the core ADK feature.

The agent receives the user's request:

```
write a joke
```

and decides how to accomplish it.

ADK's agent model is specifically designed around an LLM agent that can use tools. Google's current documentation describes `LlmAgent` as the LLM-based agent type. ([Google GitHub](https://google.github.io/adk-docs/api-reference/java/com/google/adk/agents/package-use.html?utm_source=chatgpt.com))

---

### **2\. Custom tools**

This is probably the **most important ADK feature we're using**.

We define ordinary Python functions:

```py
def get_vim_buffer():
    ...

def insert_after_line(line_number, text):
    ...

def replace_lines(start_line, end_line, text):
    ...
```

and give them to the agent:

```py
tools=[
    get_vim_buffer,
    insert_after_line,
    replace_lines,
]
```

ADK turns those Python functions into tools available to the LLM. Google's documentation explicitly describes ADK tools as ordinary Python functions whose descriptions/docstrings tell the model when and how to use them. ([Google GitHub](https://google.github.io/agents-cli/guide/hands-on-tutorial/?utm_source=chatgpt.com))

This gives us the really interesting architecture:

```
                 ADK Agent
                     │
          ┌──────────┼──────────┐
          │          │          │
          ▼          ▼          ▼
     get_buffer   insert      replace
          │          │          │
          └──────────┼──────────┘
                     │
                     ▼
                Vim bridge
```

The agent doesn't know anything about Vim's `append()` function.

It knows:

> "I have a tool called `insert_after_line`."

---

### **3\. Tool calling / agent reasoning loop**

Suppose you enter:

```
:Agent write a joke
```

The Python bridge gives ADK the request.

The model might reason:

```
I need to understand the document first.
```

So it calls:

```py
get_vim_buffer()
```

ADK executes the Python function and gives the result back to the model.

Then the model decides:

```
I'll insert a joke after the current line.
```

and calls:

```py
insert_after_line(...)
```

ADK executes that function.

So conceptually:

```
User
 │
 ▼
ADK
 │
 ▼
LLM
 │
 ├── tool: get_vim_buffer()
 │        │
 │        ▼
 │     Python
 │        │
 │        ▼
 │     buffer
 │
 ▼
LLM
 │
 └── tool: insert_after_line()
          │
          ▼
       pending edit
```

That **tool-use loop** is the central agent behavior we're exploiting.

---

### **4\. `Runner`**

We're also using:

```py
runner = Runner(
    agent=root_agent,
    app_name="vim_writer",
    session_service=session_service,
)
```

The `Runner` is what actually runs the agent.

Then:

```py
events = runner.run_async(
    user_id="vim_user",
    session_id=session_id,
    new_message=content,
)
```

starts the agent execution.

So the distinction is:

```
Agent
  = defines what the agent is

Runner
  = executes the agent
```

This becomes increasingly important as we add more sophisticated behavior.

---

### **5\. Sessions**

Our prototype also uses:

```py
session_service = InMemorySessionService()
```

and:

```py
await session_service.create_session(
    app_name="vim_writer",
    user_id="vim_user",
    session_id=session_id,
)
```

A session gives ADK a place to associate the interaction and its events/context. ADK's session services manage sessions and their associated events; `InMemorySessionService` is the in-memory implementation. ([Google GitHub](https://google.github.io/adk-docs/api-reference/java/com/google/adk/sessions/BaseSessionService.html?utm_source=chatgpt.com))

**However, our current implementation isn't taking much advantage of this yet.**

In fact, we're creating a new session for each `:Agent` request:

```
:Agent write a joke
      ↓
new session
      ↓
agent
      ↓
done

:Agent continue
      ↓
another new session
      ↓
agent
      ↓
done
```

That's something I'd change next.

A persistent session would let us do:

```
:Agent start writing an introduction
      ↓
      Agent

:Agent continue
      ↓
      Agent remembers conversation

:Agent make that more concise
      ↓
      Agent knows what "that" means
```

That's where ADK's session capabilities become much more useful.

---

### **6\. LiteLLM model integration**

We're also using:

```py
local_model = LiteLlm(
    model="ollama_chat/gemma4:26b",
    api_base="http://localhost:11434",
)
```

This is the part that connects ADK to your actual LLM.

The architecture is therefore:

```
                   Google ADK
                       │
                       ▼
                    Agent
                       │
                       ▼
                    Runner
                       │
                       ▼
                   LiteLLM
                       │
                       ▼
                    Ollama
                       │
                       ▼
                  Gemma model
```

This is important because **ADK isn't the LLM**.

ADK is orchestrating the agent.

---

## **What is NOT Google ADK**

This distinction is useful for understanding the project.

### **Vim job/channel**

This:

```
job_start(...)
ch_sendraw(...)
```

is **Vim**, not ADK.

It gives us:

```
Vim ↔ Python
```

### **JSON protocol**

This:

```py
json.dumps(...)
json.loads(...)
```

is our own communication protocol.

### **Buffer editing**

This:

```
append(...)
```

is Vimscript.

### **Conflict detection**

This:

```
b:changedtick
```

is Vim's mechanism, not ADK.

### **Human approval**

Right now we're actually doing something simpler than ADK's more formal human-in-the-loop mechanisms:

```
Agent proposes/returns edit
        ↓
Vim applies it
```

We're relying on the Vim user to initiate the operation and on `changedtick` to prevent stale edits.

---

# **So the ADK portion is surprisingly small**

I'd summarize our current project like this:

| Component | Technology | Purpose |
| ----- | ----- | ----- |
| Editor | Vim | Owns live document |
| Editor integration | Vimscript | Communicates with Python |
| IPC | Vim jobs/channels \+ JSON | Vim ↔ Python |
| Agent framework | **Google ADK** | Agent/tool orchestration |
| Agent | **ADK `Agent`** | Defines co-writer |
| Tools | **ADK custom tools** | Give agent access to document |
| Execution | **ADK `Runner`** | Runs agent |
| Session | **ADK `InMemorySessionService`** | Agent conversation/session |
| Model adapter | **LiteLLM** | Connects ADK to Ollama |
| Model | Gemma via Ollama | Generates/reasons |
| Conflict protection | Vim `b:changedtick` | Prevents stale edits |

The really important insight is that **the agent's capabilities come from the tools we give it**.

Right now:

```py
tools=[
    get_vim_buffer,
    insert_after_line,
    replace_lines,
]
```

means:

> "This agent is allowed to inspect and propose modifications to the Vim document."

If we add:

```py
get_current_file()
```

we give it another capability.

If we add:

```py
run_python()
```

we give it another capability.

If we add:

```py
search_web()
```

we give it another capability.

That's the core ADK design pattern: **LLM \+ instructions \+ tools \+ runtime**. Google's current ADK examples similarly construct an `Agent` with an instruction, model, and Python tools. ([Google GitHub](https://google.github.io/agents-cli/guide/hands-on-tutorial/?utm_source=chatgpt.com))



