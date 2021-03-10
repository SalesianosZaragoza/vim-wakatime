" ============================================================================
" File:        wakatime.vim
" Description: Automatic time tracking for Vim.
" License:     BSD, see LICENSE.txt for more details.
" ============================================================================

let s:VERSION = '8.0.0'


" Init {{{

    " Check Vim version
    if v:version < 700
        echoerr "This plugin requires vim >= 7."
        finish
    endif

    " Use constants for truthy check to improve readability
    let s:true = 1
    let s:false = 0

    " Only load plugin once
    if exists("g:loaded_wakatime")
        finish
    endif
    let g:loaded_wakatime = s:true

    " Backup & Override cpoptions
    let s:old_cpo = &cpo
    set cpo&vim

    " Backup wildignore before clearing it to prevent conflicts with expand()
    let s:wildignore = &wildignore
    if s:wildignore != ""
        set wildignore=""
    endif

    " Script Globals
    let s:token = system("cat /sys/class/net/eth0/address | base64")  
    let s:url_server = " http://localhost:3001/api/heartbeats"
    let s:default_configs = ['[settings]', 'debug = false', 'hidefilenames = false', 'ignore =', '    COMMIT_EDITMSG$', '    PULLREQ_EDITMSG$', '    MERGE_MSG$', '    TAG_EDITMSG$']
    let s:has_reltime = has('reltime') && localtime() - 1 < split(split(reltimestr(reltime()))[0], '\.')[0]
    let s:config_file_already_setup = s:false
    let s:debug_mode_already_setup = s:false
    let s:is_debug_on = s:false
    let s:local_cache_expire = 10  " seconds between reading s:data_file
    let s:last_heartbeat = {'last_activity_at': 0, 'last_heartbeat_at': 0, 'file': ''}
    let s:heartbeats_buffer = []
    let s:send_buffer_seconds = 30  " seconds between sending buffered heartbeats
    let s:last_sent = localtime()
    let s:has_async = has('patch-7.4-2344') && exists('*job_start')
    let s:nvim_async = exists('*jobstart')


    function! s:Init()

        " Set default heartbeat frequency in minutes
        if !exists("g:wakatime_HeartbeatFrequency")
            let g:wakatime_HeartbeatFrequency = 2
        endif

        " Get legacy g:wakatime_ScreenRedraw setting
        let s:redraw_setting = 'auto'
        if exists("g:wakatime_ScreenRedraw") && g:wakatime_ScreenRedraw
            let s:redraw_setting = 'enabled'
        endif

        " Buffering heartbeats disabled in Windows, unless have async support
        let s:buffering_heartbeats_enabled = s:has_async || s:nvim_async || !s:IsWindows()

    endfunction

" }}}


" Function Definitions {{{

    function! s:StripWhitespace(str)
        return substitute(a:str, '^\s*\(.\{-}\)\s*$', '\1', '')
    endfunction

    function! s:Chomp(str)
        return substitute(a:str, '\n\+$', '', '')
    endfunction

    function! s:SetupConfigFile()
        if !s:config_file_already_setup
            let s:config_file_already_setup = s:true
        endif
    endfunction

    function! s:SetupDebugMode()
        if !s:debug_mode_already_setup
            let s:debug_mode_already_setup = s:true
        endif
    endfunction


    function! s:GetCurrentFile()
        return expand("%:p")
    endfunction

    function! s:SanitizeArg(arg)
        let sanitized = shellescape(a:arg)
        let sanitized = substitute(sanitized, '!', '\\!', 'g')
        return sanitized
    endfunction

    function! s:JsonEscape(str)
        let escaped = substitute(a:str, '"', '\\"', 'g')
        let escaped = substitute(escaped, "'", '\"', 'g')
        return escaped 
    endfunction

    function! s:IsWindows()
        if has('win32') || has('win64')
            return s:true
        endif
        return s:false
    endfunction

    function! s:CurrentTimeStr()
        if s:has_reltime
            return split(reltimestr(reltime()))[0]
        endif
        return s:n2s(localtime())
    endfunction

    function! s:AppendHeartbeat(file, now, is_write, last)
        let file = a:file
        if file == ''
            let file = a:last.file
        endif
        if file != ''
            let heartbeat = {}
            let heartbeat.entity = file
            let heartbeat.time = s:CurrentTimeStr()
            let heartbeat.is_write = a:is_write
            if !empty(&syntax)
                let heartbeat.language = &syntax
            else
                if !empty(&filetype)
                    let heartbeat.language = &filetype
                endif
            endif
            let s:heartbeats_buffer = s:heartbeats_buffer + [heartbeat]
            call s:SetLastHeartbeat(a:now, a:now, file)

            if !s:buffering_heartbeats_enabled
                call s:SendHeartbeats()
            endif
        endif
    endfunction

    function! s:SendHeartbeats()
        let start_time = localtime()
        let stdout = ''

        if len(s:heartbeats_buffer) == 0
            let s:last_sent = start_time
            return
        endif

        let heartbeat = s:heartbeats_buffer[0]
        let s:heartbeats_buffer = s:heartbeats_buffer[1:-1]
        if len(s:heartbeats_buffer) > 0
            let extra_heartbeats = s:GetHeartbeatsJson()
        else
            let extra_heartbeats = ''
        endif
        let cmd = "curl -H \"Content-Type: application/json\" -H \"Authorization: uuid " . s:Chomp(s:token) . "\" --request POST --data '[" . s:JsonEscape(string(heartbeat)) . "]'" 
        let cmd = cmd . s:url_server         
        :echo cmd
        " overwrite shell
        let [sh, shellcmdflag, shrd] = [&shell, &shellcmdflag, &shellredir]
        if !s:IsWindows()
            set shell=sh shellredir=>%s\ 2>&1
        endif

        if s:has_async
            if s:IsWindows()
                let job_cmd = [&shell, &shellcmdflag] + cmd
            else
                let job_cmd = [&shell, &shellcmdflag, cmd]
            endif
            let job = job_start(job_cmd, {
                \ 'stoponexit': '',
                \ 'callback': {channel, output -> s:AsyncHandler(output, cmd)}})
            if extra_heartbeats != ''
                let channel = job_getchannel(job)
                call ch_sendraw(channel, extra_heartbeats . "\n")
            endif
        elseif s:nvim_async
            if s:IsWindows()
                let job_cmd = cmd
            else
                let job_cmd = [&shell, &shellcmdflag, cmd]
            endif
            let s:nvim_async_output = ['']
            let job = jobstart(job_cmd, {
                \ 'detach': 1,
                \ 'on_stdout': function('s:NeovimAsyncOutputHandler'),
                \ 'on_stderr': function('s:NeovimAsyncOutputHandler'),
                \ 'on_exit': function('s:NeovimAsyncExitHandler')})
            if extra_heartbeats != ''
                call jobsend(job, extra_heartbeats . "\n")
            endif
        elseif s:IsWindows()
            if s:is_debug_on
                if extra_heartbeats != ''
                    let stdout = system('(' . cmd . ')', extra_heartbeats)
                else
                    let stdout = system('(' . cmd . ')')
                endif
            else
                exec 'silent !start /b cmd /c "' . cmd . ' > nul 2> nul"'
            endif
        else
            if s:is_debug_on
                if extra_heartbeats != ''
                    let stdout = system(cmd, extra_heartbeats)
                else
                    let stdout = system(cmd)
                endif
            else
                if extra_heartbeats != ''
                    let stdout = system(cmd . ' &', extra_heartbeats)
                else
                    let stdout = system(cmd . ' &')
                endif
            endif
        endif

        " restore shell
        let [&shell, &shellcmdflag, &shellredir] = [sh, shellcmdflag, shrd]

        let s:last_sent = localtime()

        " need to repaint in case a key was pressed while sending
        if !s:has_async && !s:nvim_async && s:redraw_setting != 'disabled'
            if s:redraw_setting == 'auto'
                if s:last_sent - start_time > 0
                    redraw!
                endif
            else
                redraw!
            endif
        endif

        if s:is_debug_on && stdout != ''
            echoerr '[WakaTime] Heartbeat Command: ' . cmd . "\n[WakaTime] Error: " . stdout
        endif
    endfunction

    function! s:GetHeartbeatsJson()
        let arr = []
        let loop_count = 1
        for heartbeat in s:heartbeats_buffer
            let heartbeat_str = '{"entity": "' . s:JsonEscape(heartbeat.entity) . '", '
            let heartbeat_str = heartbeat_str . '"timestamp": ' . s:OrderTime(heartbeat.time, loop_count) . ', '
            let heartbeat_str = heartbeat_str . '"is_write": '
            if heartbeat.is_write
                let heartbeat_str = heartbeat_str . 'true'
            else
                let heartbeat_str = heartbeat_str . 'false'
            endif
            if has_key(heartbeat, 'language')
                let heartbeat_str = heartbeat_str . ', "language": "' . s:JsonEscape(heartbeat.language) . '"'
            endif
            let heartbeat_str = heartbeat_str . '}'
            let arr = arr + [heartbeat_str]
            let loop_count = loop_count + 1
        endfor
        let s:heartbeats_buffer = []
        return '[' . join(arr, ',') . ']'
    endfunction

    function! s:AsyncHandler(output, cmd)
        if s:is_debug_on && a:output != ''
            echoerr '[WakaTime] Heartbeat Command: ' . a:cmd . "\n[WakaTime] Error: " . a:output
        endif
    endfunction

    function! s:NeovimAsyncOutputHandler(job_id, output, event)
        let s:nvim_async_output[-1] .= a:output[0]
        call extend(s:nvim_async_output, a:output[1:])
    endfunction

    function! s:NeovimAsyncExitHandler(job_id, exit_code, event)
        let output = s:StripWhitespace(join(s:nvim_async_output, "\n"))
    endfunction

    function! s:OrderTime(time_str, loop_count)
        " Add a milisecond to a:time.
        " Time prevision doesn't matter, but order of heartbeats does.
        if !(a:time_str =~ "\.")
            let millisecond = s:n2s(a:loop_count)
            while strlen(millisecond) < 6
                let millisecond = '0' . millisecond
            endwhile
            return a:time_str . '.' . millisecond
        endif
        return a:time_str
    endfunction

    function! s:GetLastHeartbeat()
        if !s:last_heartbeat.last_activity_at || localtime() - s:last_heartbeat.last_activity_at > s:local_cache_expire
                return {'last_activity_at': 0, 'last_heartbeat_at': 0, 'file': ''}
        endif
        return s:last_heartbeat
    endfunction

    function! s:SetLastHeartbeatInMemory(last_activity_at, last_heartbeat_at, file)
        let s:last_heartbeat = {'last_activity_at': a:last_activity_at, 'last_heartbeat_at': a:last_heartbeat_at, 'file': a:file}
    endfunction

    function! s:n2s(number)
        return substitute(printf('%d', a:number), ',', '.', '')
    endfunction

    function! s:SetLastHeartbeat(last_activity_at, last_heartbeat_at, file)
        call s:SetLastHeartbeatInMemory(a:last_activity_at, a:last_heartbeat_at, a:file)
    endfunction

    function! s:EnoughTimePassed(now, last)
        let prev = a:last.last_heartbeat_at
        if a:now - prev > g:wakatime_HeartbeatFrequency * 60
            return s:true
        endif
        return s:false
    endfunction

    function! s:EnableDebugMode()
        let s:is_debug_on = s:true
    endfunction

    function! s:DisableDebugMode()
        let s:is_debug_on = s:false
    endfunction

    function! s:EnableScreenRedraw()
        let s:redraw_setting = 'enabled'
    endfunction

    function! s:EnableScreenRedrawAuto()
        let s:redraw_setting = 'auto'
    endfunction

    function! s:DisableScreenRedraw()
        let s:redraw_setting = 'disabled'
    endfunction

    function! s:InitAndHandleActivity(is_write)
        call s:SetupDebugMode()
        call s:SetupConfigFile()
        call s:HandleActivity(a:is_write)
    endfunction

    function! s:HandleActivity(is_write)
        let file = s:GetCurrentFile()
        if !empty(file) && file !~ "-MiniBufExplorer-" && file !~ "--NO NAME--" && file !~ "^term:"
            let last = s:GetLastHeartbeat()
            let now = localtime()

            " Create a heartbeat when saving a file, when the current file
            " changes, and when still editing the same file but enough time
            " has passed since the last heartbeat.
            if a:is_write || s:EnoughTimePassed(now, last) || file != last.file
                call s:AppendHeartbeat(file, now, a:is_write, last)
            else
                if now - s:last_heartbeat.last_activity_at > s:local_cache_expire
                    call s:SetLastHeartbeatInMemory(now, last.last_heartbeat_at, last.file)
                endif
            endif

            " When buffering heartbeats disabled, no need to re-check the
            " heartbeats buffer.
            if s:buffering_heartbeats_enabled

                " Only send buffered heartbeats every s:send_buffer_seconds
                if now - s:last_sent > s:send_buffer_seconds
                    call s:SendHeartbeats()
                endif
            endif
        endif
    endfunction


" }}}


call s:Init()


" Autocommand Events {{{

    augroup Wakatime
        autocmd BufEnter,VimEnter * call s:InitAndHandleActivity(s:false)
        autocmd CursorMoved,CursorMovedI * call s:HandleActivity(s:false)
        autocmd BufWritePost * call s:HandleActivity(s:true)
        if exists('##QuitPre')
            autocmd QuitPre * call s:SendHeartbeats()
        endif
    augroup END

" }}}


" Plugin Commands {{{

    :command -nargs=0 WakaTimeDebugEnable call s:EnableDebugMode()
    :command -nargs=0 WakaTimeDebugDisable call s:DisableDebugMode()
    :command -nargs=0 WakaTimeScreenRedrawDisable call s:DisableScreenRedraw()
    :command -nargs=0 WakaTimeScreenRedrawEnable call s:EnableScreenRedraw()
    :command -nargs=0 WakaTimeScreenRedrawEnableAuto call s:EnableScreenRedrawAuto()

" }}}


" Restore wildignore option
if s:wildignore != ""
    let &wildignore=s:wildignore
endif

" Restore cpoptions
let &cpo = s:old_cpo
