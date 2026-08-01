# PSScriptAnalyzer configuration for claude-autoswitch.
#
# Every exclusion below is a deliberate, documented decision - not a way to
# silence inconvenient findings. Anything not listed here is expected to pass,
# and CI fails on any remaining Error or Warning (see tests/lint.ps1).
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # These scripts are an interactive console CLI: the formatted output IS
        # the user interface. Write-Output would push that text into the
        # pipeline and corrupt return values - notably in statusline.ps1, where
        # exactly one Write-Output line is the contract with Claude Code.
        'PSAvoidUsingWriteHost',

        # Intentional best-effort swallows, all in places where failing loudly
        # would be worse than doing nothing:
        #   common.ps1     Write-Log      - logging must never break a switch
        #   statusline.ps1 stdin/state    - a bad parse must not break the prompt
        #   uninstall.ps1  Unregister     - the task may legitimately not exist
        #   tests/*        cleanup guards - teardown runs even after a failure
        'PSAvoidUsingEmptyCatchBlock',

        # common.ps1 is dot-sourced, so its shared variables ($DataDir,
        # $ProjectsDir, $SettingsPath, ...) are consumed by sibling scripts the
        # analyzer cannot see. The test scripts likewise reassign those paths to
        # redirect the dot-sourced helpers at a sandbox.
        'PSUseDeclaredVarsMoreThanAssignments',

        # Set-Prop is a pure in-memory property setter, and Set-ClaudeBackend is
        # an internal helper always reached through an explicit user action
        # (claude-switch) or the monitor's own decision. Neither is a public
        # cmdlet, so -WhatIf/-Confirm plumbing would be noise.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
