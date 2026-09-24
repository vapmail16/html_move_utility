BeforeDiscovery {
    Import-Module "$PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1" -Force -DisableNameChecking
}

InModuleScope NotificationMigration {
    Describe 'Compare providers' {
        BeforeAll {
            $script:opts = @{ timestampToleranceSec = 0; ignoreAttributes = @() }
            function New-Rec {
                param([hashtable] $Set = @{})
                $r = @{
                    rel_path = '2019\03\a.html'; kind = 'file'; size_bytes = 10; hash = 'ABC'; hash_algo = 'SHA256'
                    created_utc = '2019-03-01T10:00:00.0000000Z'; modified_utc = '2019-03-02T10:00:00.0000000Z'
                    attributes = 'Archive'; acl_hash = 'ACL1'; error = $null
                }
                foreach ($k in $Set.Keys) { $r[$k] = $Set[$k] }
                return $r
            }
            function Invoke-Cmp {
                param([string] $Name, $Source, $Target, $Options = $script:opts)
                $p = Get-MigProvider -Kind Compare -Name $Name
                return (& $p $null $Source $Target $Options)
            }
        }

        It 'registers every field name used by compare.fileFields' {
            $names = Get-MigProviderNames -Kind Compare
            foreach ($n in @('exists', 'size', 'hash', 'created', 'modified', 'attributes', 'acl')) { $names | Should -Contain $n }
        }

        It 'returns $null for identical records on every provider' {
            foreach ($n in @('exists', 'size', 'hash', 'created', 'modified', 'attributes', 'acl')) {
                Invoke-Cmp $n (New-Rec) (New-Rec) | Should -BeNullOrEmpty -Because $n
            }
        }

        Context 'exists' {
            It 'detects a missing target, a tombstoned target and an extra' {
                Invoke-Cmp 'exists' (New-Rec) $null | Should -Match 'missing on target'
                Invoke-Cmp 'exists' (New-Rec) (New-Rec @{ deleted = $true }) | Should -Match 'missing on target'
                Invoke-Cmp 'exists' $null (New-Rec) | Should -Match 'not on source'
            }
            It 'detects a file/dir kind difference' {
                Invoke-Cmp 'exists' (New-Rec) (New-Rec @{ kind = 'dir' }) | Should -Match 'kind differs'
            }
        }

        Context 'size / hash' {
            It 'detects a size difference' {
                Invoke-Cmp 'size' (New-Rec) (New-Rec @{ size_bytes = 11 }) | Should -Match 'size differs'
            }
            It 'compares numbers regardless of their JSON integer type' {
                Invoke-Cmp 'size' (New-Rec @{ size_bytes = [int64]10 }) (New-Rec @{ size_bytes = [int32]10 }) | Should -BeNullOrEmpty
            }
            It 'detects a hash difference (case-insensitive equality otherwise)' {
                Invoke-Cmp 'hash' (New-Rec) (New-Rec @{ hash = 'abd' }) | Should -Match 'differs'
                Invoke-Cmp 'hash' (New-Rec) (New-Rec @{ hash = 'abc' }) | Should -BeNullOrEmpty
            }
            It 'fails when the hash algorithm differs' {
                Invoke-Cmp 'hash' (New-Rec) (New-Rec @{ hash_algo = 'SHA512' }) | Should -Match 'algorithm differs'
            }
            It 'fails when either hash is null' {
                Invoke-Cmp 'hash' (New-Rec @{ hash = $null }) (New-Rec) | Should -Match 'hash missing'
                Invoke-Cmp 'hash' (New-Rec) (New-Rec @{ hash = $null }) | Should -Match 'hash missing'
            }
            It 'does not double-report when a side is absent (exists owns that)' {
                Invoke-Cmp 'hash' (New-Rec) $null | Should -BeNullOrEmpty
                Invoke-Cmp 'size' (New-Rec) $null | Should -BeNullOrEmpty
            }
            It 'ignores size/hash for directories' {
                Invoke-Cmp 'hash' (New-Rec @{ kind = 'dir'; hash = $null }) (New-Rec @{ kind = 'dir'; hash = $null }) | Should -BeNullOrEmpty
            }
        }

        Context 'timestamps' {
            It 'detects a modified difference' {
                Invoke-Cmp 'modified' (New-Rec) (New-Rec @{ modified_utc = '2019-03-02T10:00:01.0000000Z' }) | Should -Match 'modified differs by 1s'
            }
            It 'detects a created difference' {
                Invoke-Cmp 'created' (New-Rec) (New-Rec @{ created_utc = '2020-01-01T00:00:00.0000000Z' }) | Should -Match 'created differs'
            }
            It 'honours compare.timestampToleranceSec' {
                $o = @{ timestampToleranceSec = 2 }
                Invoke-Cmp 'modified' (New-Rec) (New-Rec @{ modified_utc = '2019-03-02T10:00:02.0000000Z' }) $o | Should -BeNullOrEmpty
                Invoke-Cmp 'modified' (New-Rec) (New-Rec @{ modified_utc = '2019-03-02T10:00:03.0000000Z' }) $o | Should -Not -BeNullOrEmpty
            }
            It 'treats a [DateTime] (as returned by JSON readers) and the ISO string as equal' {
                $dt = [DateTime]::SpecifyKind([DateTime]'2019-03-02T10:00:00', [DateTimeKind]::Utc)
                Invoke-Cmp 'modified' (New-Rec) (New-Rec @{ modified_utc = $dt }) | Should -BeNullOrEmpty
                Invoke-Cmp 'modified' (New-Rec) (New-Rec @{ modified_utc = $dt.ToLocalTime() }) | Should -BeNullOrEmpty
            }
            It 'reports an unknown timestamp on one side' {
                Invoke-Cmp 'modified' (New-Rec) (New-Rec @{ modified_utc = $null }) | Should -Match 'unknown'
            }
        }

        Context 'attributes / acl' {
            It 'compares attribute sets order-insensitively' {
                Invoke-Cmp 'attributes' (New-Rec @{ attributes = 'ReadOnly, Archive' }) (New-Rec @{ attributes = 'Archive, ReadOnly' }) | Should -BeNullOrEmpty
                Invoke-Cmp 'attributes' (New-Rec @{ attributes = 'ReadOnly, Archive' }) (New-Rec @{ attributes = 'Archive' }) | Should -Match 'attributes differ'
            }
            It 'honours compare.ignoreAttributes and treats Normal as no attributes' {
                Invoke-Cmp 'attributes' (New-Rec @{ attributes = 'Archive' }) (New-Rec @{ attributes = 'Normal' }) @{ ignoreAttributes = @('Archive') } | Should -BeNullOrEmpty
            }
            It 'detects an ACL difference and a one-sided ACL hash' {
                Invoke-Cmp 'acl' (New-Rec) (New-Rec @{ acl_hash = 'ACL2' }) | Should -Match 'ACL differs'
                Invoke-Cmp 'acl' (New-Rec) (New-Rec @{ acl_hash = $null }) | Should -Match 'missing'
                Invoke-Cmp 'acl' (New-Rec @{ acl_hash = $null }) (New-Rec @{ acl_hash = $null }) | Should -BeNullOrEmpty
            }
        }
    }
}
