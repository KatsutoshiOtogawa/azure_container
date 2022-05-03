# azure cliでなくて、msのドキュメント的にもazure powershellがデフォルト担ったら
# azure powershellで書き換える。

# github action用のprincipal作成とgithub actionの
function set_azure_acr_for_github {
    #Requires -Version 7 
    [CmdletBinding()]
    param (
        # UseMaximumSize
        [Parameter(
            Mandatory = $True
            , HelpMessage = "github repository for github action"
        )]
        [String]$repo

    )
    Set-Variable ErrorActionPreference -Scope local -Value "Stop"

    # github repositoryが存在するか確認
    try {
        Invoke-WebRequest "https://api.github.com/repos/${repo}" | Out-Null
    } catch {

        $error[0] | Write-Error
    }

    # get azure resouce group name list
    az group list --query "[].{Name:name}" | ConvertFrom-Json | Set-Variable rg_list -Scope local

    # get azure resouce group
    New-Variable rg_group -Scope local
    while ($true) {
        Write-Output $rg_list | Out-String | Out-Host
        read-host "Type you use resource group >" | Set-Variable select_name -Scope local

        # resource groupの存在確認
        if (-not [String]::IsNullOrEmpty($(az group list --query "[?name=='${select_name}'].{Name:name}" --output tsv))){
            $rg_group = (az group list --query "[?name=='${select_name}']" | 
                ConvertFrom-Json)
            break;
        }else {
            Write-Host "Select exists resource group!"
        }
    }

    New-TemporaryFile | Set-Variable principal_json -Scope local -Option Constant

    try {

        # サービスプリンシパルを作成し、
        az ad sp create-for-rbac `
            --scope $rg_group.id `
            --role Contributor `
            --sdk-auth | 
            Tee-Object -FilePath $principal_json.FullName -Encoding utf8NoBOM |
            ConvertFrom-Json | 
            Set-Variable principal -Scope local -Option Constant
        

        # container registryのリストを取得
        az acr list --query "[].{Name:name}" | ConvertFrom-Json | Set-Variable acr_list -Scope local

        # get contaier registry name
        New-Variable acr_name -Scope local
        while ($true) {
            Write-Output $acr_list | Out-String | Out-Host
            read-host "Type you use acr_name >" | Set-Variable select_name -Scope local

            # registryの存在確認
            if (-not [String]::IsNullOrEmpty($(az acr list --query "[?name=='${select_name}'].{Name:name}" --output tsv))){
                $acr = (az acr list --query "[?name=='${select_name}']" | 
                    ConvertFrom-Json)
                break;
            }else {
                Write-Host "Select exists acr!"
            }
        }

        az role assignment create `
            --assignee $principal.clientId `
            --scope $acr.id `
            --role AcrPush | Out-Null
        
        # github secretにaction用の環境変数を設定
        # workload identityがGAになったらそっちを使う。

        # AZURE_CREDENTIALS	サービス プリンシパルの作成ステップからの JSON 出力全体
        # REGISTRY_LOGIN_SERVER	レジストリのログイン サーバー名 (すべて小文字)。 例: myregistry.azurecr.io
        # REGISTRY_USERNAME	サービス プリンシパルの作成からの JSON 出力からの clientId
        # REGISTRY_PASSWORD	サービス プリンシパルの作成からの JSON 出力からの clientSecret
        # RESOURCE_GROUP	サービス プリンシパルのスコープ指定に使用したリソース グループの名前


        # pwsh では<が使えないのでそれぞれのOSのデフォルトのシェルを呼び出す。
        # -eq UnixでLinux系も吸収できてる
        if ($PSVersionTable.Platform -eq "Unix") {
            /bin/sh -c "gh secret set AZURE_CREDENTIALS --repo $repo < $($principal_json.FullName)"
        } else {

            # cmd実行用のファイルを作成
            New-TemporaryFile | Set-Variable tempfile -Scope local -Option Constant
            ($tempfile.FullName -replace "\..*$",".bat") | Set-Variable tempbat_path -Scope local -Option Constant
            Rename-Item $tempfile.FullName -NewName $tempbat_path

            Write-Output "gh secret set AZURE_CREDENTIALS --repo $repo < $($principal_json.FullName)" | Set-Content -Path $tempbat_path
            # 下のように必ずWorkingDirectoryを指定すること
            # cmdはディレクトリを跨ぐ処理ができないため。
            Start-Process $tempbat_path -WorkingDirectory (Get-Location | Select-Object -ExpandProperty Path)
            Remove-Item $tempbat_path
        }
        
        gh secret set REGISTRY_LOGIN_SERVER --repo $repo --body $acr.loginServer
        gh secret set REGISTRY_USERNAME --repo $repo --body $principal.clientId
        gh secret set REGISTRY_PASSWORD --repo $repo --body $principal.clientSecret
        gh secret set RESOURCE_GROUP --repo $repo --body $rg_group.name
    } finally {
        # 一時ファイルを確実に削除
        Remove-Item $principal_json.FullName
    }

}
