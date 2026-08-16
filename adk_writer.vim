" ============================================================
" Place this file inside the ~/.vim/plugin directory 
" Set the path of the python executable and the python ADK bridge
" Vim <-> Google ADK co-writing bridge
"
" Vim owns the document buffer.
" The ADK agent never directly reads or writes the file.
"
" ============================================================


" ============================================================
" REQUIREMENTS
" ============================================================

if !has('job') || !has('channel')
    echoerr 'ADK Writer requires Vim with +job and +channel support'
    finish
endif


" ============================================================
" CONFIGURATION
" ============================================================

" Python executable from the Google ADK virtual environment.
let g:adk_writer_python =
            \ '/path-to-the/google_adk/bin/python'

" Python ADK bridge.
let g:adk_writer_bridge =
            \ '/path-to-the/vim-adk-writer/adk_bridge.py'


" ============================================================
" STATE
" ============================================================

let s:agent_job = v:null


" ============================================================
" START ADK AGENT
" ============================================================

function! s:StartAgent() abort

    " Already running?
    if type(s:agent_job) == v:t_job

        if job_status(s:agent_job) ==# 'run'
            return 1
        endif

    endif


    " Command that Vim will execute.
    let l:command = [
                \ g:adk_writer_python,
                \ g:adk_writer_bridge
                \ ]


    echom 'ADK command: ' . string(l:command)


    " Start the persistent Python process.
    let s:agent_job = job_start(
                \ l:command,
                \ {
                \   'in_mode': 'nl',
                \   'out_mode': 'nl',
                \   'err_mode': 'nl',
                \   'out_cb': function('s:OnAgentOutput'),
                \   'err_cb': function('s:OnAgentError'),
                \ }
                \ )


    if job_status(s:agent_job) !=# 'run'

        echoerr 'ADK Writer: unable to start Python bridge'

        return 0

    endif


    echom 'ADK writer started'

    return 1

endfunction


" ============================================================
" SEND REQUEST TO ADK
" ============================================================

function! s:Request(instruction) abort

    if !s:StartAgent()
        return
    endif


    " --------------------------------------------------------
    " Remember the current Vim state.
    " --------------------------------------------------------

    let l:buf = bufnr('%')

    let l:payload = {
                \ 'type': 'edit_request',
                \ 'instruction': a:instruction,
                \ 'bufnr': l:buf,
                \ 'filename': expand('%:p'),
                \ 'filetype': &filetype,
                \ 'lines': getbufline(l:buf, 1, '$'),
                \ 'cursor_line': line('.'),
                \ 'cursor_col': col('.'),
                \ 'changedtick': b:changedtick
                \ }


    " --------------------------------------------------------
    " Convert request to JSON.
    " --------------------------------------------------------

    let l:json = json_encode(l:payload)


    " --------------------------------------------------------
    " Send JSON to Python.
    " --------------------------------------------------------

    call ch_sendraw(
                \ job_getchannel(s:agent_job),
                \ l:json . "\n"
                \ )


    echom 'ADK writer: request sent'

endfunction


" ============================================================
" RECEIVE RESPONSE FROM ADK
" ============================================================

function! s:OnAgentOutput(channel, message) abort

    " --------------------------------------------------------
    " Decode JSON.
    " --------------------------------------------------------

    try

        let l:response = json_decode(a:message)

    catch

        echohl ErrorMsg
        echom 'ADK writer: invalid JSON response'
        echom a:message
        echohl None

        return

    endtry


    if type(l:response) != v:t_dict
        return
    endif


    " --------------------------------------------------------
    " Handle agent errors.
    " --------------------------------------------------------

    if get(l:response, 'type', '') ==# 'error'

        echohl ErrorMsg

        echom 'ADK writer error: ' .
                    \ get(l:response, 'message', 'unknown error')

        echohl None

        return

    endif


    " --------------------------------------------------------
    " Ignore messages that aren't results.
    " --------------------------------------------------------

    if get(l:response, 'type', '') !=# 'result'
        return
    endif


    " --------------------------------------------------------
    " Identify target buffer.
    " --------------------------------------------------------

    let l:buf = get(l:response, 'bufnr', -1)


    if !bufloaded(l:buf)

        echohl WarningMsg
        echom 'ADK writer: target buffer is no longer loaded'
        echohl None

        return

    endif


    " ========================================================
    " CONFLICT DETECTION
    "
    " The agent was given a snapshot of the buffer.
    "
    " If the human edited the buffer while the agent was
    " thinking, b:changedtick will be different.
    "
    " In that case we DO NOT apply the AI edit.
    " ========================================================

    let l:agent_tick =
                \ get(l:response, 'changedtick', -1)

    let l:current_tick =
                \ getbufvar(l:buf, 'changedtick', -2)


    if l:agent_tick !=# l:current_tick

        echohl WarningMsg

        echom 'ADK writer: buffer changed while agent was working.'
        echom 'ADK writer: AI edit NOT applied.'

        echohl None

        return

    endif


    " ========================================================
    " SAVE CURRENT VIM STATE
    " ========================================================

    let l:save_win = win_getid()

    let l:save_buf = bufnr('%')

    let l:save_line = line('.')

    let l:save_col = col('.')


    " ========================================================
    " APPLY AGENT EDITS
    " ========================================================

    let l:edits = get(l:response, 'edits', [])


    if empty(l:edits)

        let l:message =
                    \ get(l:response, 'message', '')

        if !empty(l:message)

            echom 'ADK: ' . l:message

        else

            echom 'ADK writer: agent made no edit'

        endif

        return

    endif


    " --------------------------------------------------------
    " Switch to the target buffer.
    " --------------------------------------------------------

    execute 'buffer ' . l:buf


    " --------------------------------------------------------
    " Create one undo block for the entire AI edit.
    " --------------------------------------------------------

    silent! undojoin


    " --------------------------------------------------------
    " Process edits.
    " --------------------------------------------------------

    for l:edit in l:edits

        let l:operation =
                    \ get(l:edit, 'op', '')


        " ====================================================
        " INSERT AFTER LINE
        " ====================================================

        if l:operation ==# 'insert_after'

            let l:line =
                        \ get(l:edit, 'line', 0)

            let l:text =
                        \ get(l:edit, 'text', '')


            " Convert text to Vim lines.
            let l:lines =
                        \ split(l:text, "\n", 1)


            " Vim's append() works with the current buffer.
            call append(l:line, l:lines)


        " ====================================================
        " REPLACE LINES
        " ====================================================

        elseif l:operation ==# 'replace'

            let l:start =
                        \ get(l:edit, 'start', 1)

            let l:end =
                        \ get(l:edit, 'end', l:start)

            let l:text =
                        \ get(l:edit, 'text', '')


            let l:lines =
                        \ split(l:text, "\n", 1)


            " Delete the old lines.
            execute l:start . ',' . l:end . 'delete _'


            " Insert replacement.
            call append(
                        \ l:start - 1,
                        \ l:lines
                        \ )


        else

            echohl WarningMsg

            echom 'ADK writer: unknown edit operation: ' .
                        \ l:operation

            echohl None

        endif

    endfor


    " ========================================================
    " RESTORE ORIGINAL WINDOW
    " ========================================================

    if win_id2win(l:save_win) != 0

        call win_gotoid(l:save_win)

    endif


    " ========================================================
    " RESTORE ORIGINAL BUFFER
    " ========================================================

    if bufnr('%') != l:save_buf

        execute 'buffer ' . l:save_buf

    endif


    " ========================================================
    " RESTORE CURSOR
    " ========================================================

    call cursor(
                \ l:save_line,
                \ l:save_col
                \ )


    " ========================================================
    " REPORT SUCCESS
    " ========================================================

    echom 'ADK writer: edit applied'

endfunction


" ============================================================
" HANDLE STDERR FROM PYTHON
" ============================================================

function! s:OnAgentError(channel, message) abort

    if empty(a:message)
        return
    endif


    echohl WarningMsg

    echom 'ADK stderr: ' . a:message

    echohl None

endfunction


" ============================================================
" USER COMMAND
"
" Example:
"
"   :Agent write a joke
"
" ============================================================

command! -nargs=+ Agent
            \ call <SID>Request(<q-args>)


" ============================================================
" CONVENIENCE COMMAND
"
" Example:
"
"   :AgentContinue
"
" ============================================================

command! AgentContinue
            \ call <SID>Request(
            \ 'Continue writing naturally from the current cursor line.'
            \ )
