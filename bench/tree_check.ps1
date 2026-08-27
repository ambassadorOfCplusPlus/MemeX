# Is a build tree LOADABLE, not merely present. Dot-source this and call Test-TreeStartable.
#
# WHY THIS IS A SEPARATE CHECK FROM "THE BUILD SUCCEEDED".
#
# Three times now this project has lost work to a tree that reported a successful build and
# could not start a single binary. The failure has a specific and nasty shape:
#
#   * MSBuild prints the link line for a target it did not link. A build log containing
#     `ggml.vcxproj -> ...\bin\Release\ggml.dll` is not evidence that the file exists; freshness
#     is decided from the tlog directory, not from whether the output is there.
#   * The binaries then fail in the Windows loader, BEFORE main, so they print nothing at all.
#     Every log pattern that looks for an error message misses it, and an empty log reads as
#     "the run produced no data" rather than "the run never started".
#   * The two codes worth recognising by sight:
#         -1073741515  (0xC0000135)  STATUS_DLL_NOT_FOUND   - a DLL is missing outright
#         -1073741511  (0xC0000139)  STATUS_ENTRYPOINT_NOT_FOUND - the DLLs and the exe are
#                                    from different builds, i.e. a partial rebuild
#
# So the only honest check is to run something and look at its exit code. That is what this
# does, and every build script in this project should call it before it releases the machine
# lock: a build that leaves an unloadable tree is worse than a build that fails, because the
# failure surfaces three steps later inside somebody else's measurement.

# Returns $true when the tree looks loadable. Writes what it found either way, so a failure
# arrives with its evidence attached rather than as a bare boolean.
function Test-TreeStartable {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        # DLLs that must be present and non-trivial. ggml-base.dll is deliberately not here:
        # it is a stub in this fork and has been 640 KB and unchanged since June.
        [string[]]$Dlls = @('ggml.dll', 'llama.dll'),
        # Executables to actually launch. An exe that is absent is skipped rather than failed -
        # not every tree builds every target - but one that is present and will not start is a
        # failure, which is the whole point.
        [string[]]$Exes = @('llama-cli.exe'),
        [string]$Arg = '--version',
        [int]$MinDllBytes = 1048576
    )
    $ok = $true
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Host "  proverka dereva: net katalog $Dir"
        return $false
    }
    foreach ($d in $Dlls) {
        $p = Join-Path $Dir $d
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Host "  proverka dereva: NET $d - eto -1073741515 u ljubogo binarnika"
            $ok = $false
            continue
        }
        $len = (Get-Item -LiteralPath $p).Length
        if ($len -lt $MinDllBytes) {
            # The second occurrence in this project was a 67 KB ggml.dll from a month earlier
            # sitting where the 31 MB one belonged. Present is not the same as right.
            Write-Host ("  proverka dereva: {0} vsego {1:N0} bajt - podozritelno malo" -f $d, $len)
            $ok = $false
            continue
        }
        Write-Host ("  proverka dereva: {0,-12} {1,12:N0} bajt  {2}" -f $d, $len,
                    (Get-Item -LiteralPath $p).LastWriteTime)
    }
    foreach ($e in $Exes) {
        $p = Join-Path $Dir $e
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Host "  proverka dereva: $e otsutstvuet - propuskaem"
            continue
        }
        # Output discarded on purpose: the exit code is the whole answer, and a --version dump
        # in the middle of a build log is noise.
        & $p $Arg *> $null
        $code = $LASTEXITCODE
        if ($null -eq $code) {
            # Rule 55: an empty exit code is not zero, and $null -ne 0 is TRUE in PowerShell, so
            # a caller that folds this into its failure branch would report a failure it never
            # measured. Say it instead.
            Write-Host "  proverka dereva: $e - ExitCode pust, schitaem otkazom"
            $ok = $false
            continue
        }
        # A non-zero code that is NOT a loader code means the program started and then refused
        # the argument, which is the opposite of what this check is looking for. llama-memex-fwd
        # has no --version and answers exit 1; calling that unloadable would be the check crying
        # wolf, and a check that cries wolf gets ignored on the day it is right. So: retry with
        # --help, and only report a failure if the program will not start under either.
        $loader = ($code -eq -1073741515 -or $code -eq -1073741511)
        if ($code -ne 0 -and -not $loader -and $Arg -ne '--help') {
            & $p --help *> $null
            $alt = $LASTEXITCODE
            if ($alt -eq 0) {
                Write-Host "  proverka dereva: $e ne znaet $Arg (exit $code), no --help -> 0: zapuskaetsja"
                continue
            }
        }
        $why = switch ($code) {
            -1073741515 { ' (STATUS_DLL_NOT_FOUND - DLL ne najdena)' }
            -1073741511 { ' (STATUS_ENTRYPOINT_NOT_FOUND - DLL i exe iz raznyh sborok)' }
            default     { '' }
        }
        Write-Host "  proverka dereva: $e $Arg -> exit $code$why"
        if ($code -ne 0) { $ok = $false }
    }
    return $ok
}
