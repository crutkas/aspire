# Tips and known issues

## My containers aren't being created at all

We have seen Docker get into weird state on "DevBox" machines that get hibernated every evening. You can check if you got into this state by opening a command window and doing "docker ps". If it hangs forever without error, that is it.

The remedy is to do "Restart Docker" gesture from the Docker icon in system tray.

## If something goes wrong and you are left with a bunch of Aspire TestShop orphaned processes and containers

This will display process IDs of all the Aspire shopping running processes

```ps1
ps | where ProcessName -cmatch '(Api)|(Catalog)|(Basket)|(AppHost)|(MyFrontend)|(OrderProcessor)' | % {Write-Output $_.Id }
```

… and this will kill them

```ps1
ps | where ProcessName -cmatch '(Api)|(Catalog)|(Basket)|(AppHost)|(MyFrontend)|(OrderProcessor)' | % {Write-Output $_.Id; kill $_.Id }
```

## Power user: `AspireFastInnerLoop=true` for faster local builds

If you're iterating quickly and don't need analyzer diagnostics, code-style enforcement, or XML documentation generation on every build, you can opt into a faster build mode by setting the `AspireFastInnerLoop` MSBuild property:

```
dotnet build Aspire-Core.slnf /p:AspireFastInnerLoop=true
```

Or set it once per shell:

```
# PowerShell
$env:AspireFastInnerLoop = 'true'

# cmd
set AspireFastInnerLoop=true

# bash / zsh
export AspireFastInnerLoop=true
```

When the flag is set, the following are disabled for the duration of the build:

| Property                       | Default | With flag |
| ------------------------------ | ------- | --------- |
| `RunAnalyzers`                   | true    | false     |
| `RunAnalyzersDuringBuild`        | true    | false     |
| `EnforceCodeStyleInBuild`        | true    | false     |
| `GenerateDocumentationFile`      | true    | false     |
| `NoWarn`                         | (base)  | base + `CS1591` |

The flag is **off by default** - existing builds and CI are unaffected.

### When NOT to use it

- **CI / official builds.** Never set this in a CI environment; you would ship un-analyzed bits without code-style enforcement or XML docs.
- **Release validation.** Always do a clean build without the flag before submitting a PR.
- **Public API auditing / analyzer-driven work.** If you're investigating an analyzer warning, code-style issue, or public API change, you need the analyzers enabled.

The build emits a high-importance message when the flag is active so it's hard to miss that you're in fast-inner-loop mode.
