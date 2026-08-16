#!/usr/bin/env python3

import asyncio
import json
import sys
import uuid

from google.adk.agents import Agent
from google.adk.models.lite_llm import LiteLlm
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types


# ============================================================
# Current Vim state
#
# Vim sends a snapshot of its current in-memory buffer.
# The ADK tools below operate on that snapshot and create
# EDIT INSTRUCTIONS.
#
# They do NOT touch the file on disk.
# ============================================================

CURRENT_VIM_STATE = {}
PENDING_EDITS = []


# ============================================================
# ADK TOOLS
# ============================================================

def get_vim_buffer() -> dict:
    """
    Return the current Vim buffer, cursor position, filename,
    and filetype.

    Always call this before editing the document.
    """

    return {
        "status": "success",
        "filename": CURRENT_VIM_STATE.get("filename", ""),
        "filetype": CURRENT_VIM_STATE.get("filetype", ""),
        "cursor_line": CURRENT_VIM_STATE.get("cursor_line", 1),
        "cursor_col": CURRENT_VIM_STATE.get("cursor_col", 1),
        "lines": CURRENT_VIM_STATE.get("lines", []),
    }


def insert_after_line(line_number: int, text: str) -> dict:
    """
    Insert text after a line in the Vim buffer.

    Args:
        line_number:
            1-based Vim line number.
            Use 0 to insert before the first line.

        text:
            Text to insert. It may contain multiple lines.
    """

    lines = CURRENT_VIM_STATE.get("lines", [])

    if line_number < 0 or line_number > len(lines):
        return {
            "status": "error",
            "message": f"Invalid line number {line_number}"
        }

    PENDING_EDITS.append({
        "op": "insert_after",
        "line": line_number,
        "text": text,
    })

    return {
        "status": "success",
        "message": f"Text queued for insertion after line {line_number}"
    }


def replace_lines(start_line: int, end_line: int, text: str) -> dict:
    """
    Replace a range of lines in the Vim buffer.

    Args:
        start_line:
            First line to replace, using Vim's 1-based numbering.

        end_line:
            Last line to replace, inclusive.

        text:
            Replacement text.
    """

    lines = CURRENT_VIM_STATE.get("lines", [])

    if (
        start_line < 1
        or end_line < start_line
        or end_line > len(lines)
    ):
        return {
            "status": "error",
            "message": "Invalid line range"
        }

    PENDING_EDITS.append({
        "op": "replace",
        "start": start_line,
        "end": end_line,
        "text": text,
    })

    return {
        "status": "success",
        "message": f"Lines {start_line}-{end_line} queued for replacement"
    }


# ============================================================
# MODEL
#
# Replace this model name with whichever Ollama model already
# works in your environment.
# ============================================================

local_model = LiteLlm(
    model="ollama_chat/gemma4:26b",
    api_base="http://localhost:11434",
)


# ============================================================
# ADK AGENT
# ============================================================

root_agent = Agent(
    name="vim_cowriter",
    model=local_model,

    instruction="""
You are an AI co-writer embedded inside Vim.

You work directly with the user's CURRENT IN-MEMORY Vim buffer.

Rules:

1. Always call get_vim_buffer before making an edit.

2. Never assume that the version on disk is current.
   Only use get_vim_buffer() as the authoritative document.

3. To change the document, use:
      insert_after_line()
   or:
      replace_lines()

4. For this prototype, perform at most ONE editing operation
   per user request.

5. When the user says "continue", normally insert new text
   after the current cursor line.

6. Preserve the user's existing writing unless the user
   specifically asks you to rewrite it.

7. Never attempt to open, read, or write the file directly.

8. Keep your final response very short because the actual
   result will appear inside Vim.
""",

    tools=[
        get_vim_buffer,
        insert_after_line,
        replace_lines,
    ],
)


# ============================================================
# RUN ONE ADK REQUEST
# ============================================================

async def run_request(request: dict) -> dict:

    global CURRENT_VIM_STATE
    global PENDING_EDITS

    CURRENT_VIM_STATE = request
    PENDING_EDITS = []

    session_service = InMemorySessionService()

    session_id = str(uuid.uuid4())

    await session_service.create_session(
        app_name="vim_writer",
        user_id="vim_user",
        session_id=session_id,
    )

    runner = Runner(
        agent=root_agent,
        app_name="vim_writer",
        session_service=session_service,
    )

    content = types.Content(
        role="user",
        parts=[
            types.Part(
                text=request.get("instruction", "")
            )
        ],
    )

    final_text = ""

    events = runner.run_async(
        user_id="vim_user",
        session_id=session_id,
        new_message=content,
    )

    async for event in events:

        if event.is_final_response():

            if event.content and event.content.parts:

                final_text = "".join(
                    part.text or ""
                    for part in event.content.parts
                )

    return {
        "type": "result",

        # identify the exact Vim buffer
        "bufnr": request.get("bufnr"),

        # conflict-detection value
        "changedtick": request.get("changedtick"),

        "edits": PENDING_EDITS,

        "message": final_text,
    }


# ============================================================
# COMMUNICATION WITH VIM
#
# One JSON object per line:
#
# Vim -> Python
# Python -> Vim
# ============================================================

def emit(data: dict):

    sys.stdout.write(
        json.dumps(data, ensure_ascii=False) + "\n"
    )

    sys.stdout.flush()


async def main():

    for raw_line in sys.stdin:

        raw_line = raw_line.strip()

        if not raw_line:
            continue

        try:

            request = json.loads(raw_line)

        except Exception as exc:

            emit({
                "type": "error",
                "message": f"Invalid JSON: {exc}",
            })

            continue

        try:

            result = await run_request(request)

            emit(result)

        except Exception as exc:

            emit({
                "type": "error",
                "message": str(exc),
                "bufnr": request.get("bufnr"),
            })


if __name__ == "__main__":
    asyncio.run(main())
