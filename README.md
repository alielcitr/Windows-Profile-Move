# Windows Profile Move

**Sürüm:** 1.0
**Yazar:** ALİ ELÇİ

Bir Windows kullanıcı profilini (dosyalar, `NTUSER.DAT` registry hive'ı, NTFS izinleri ve `ProfileList` kaydı dahil) bir kullanıcı hesabından başka bir kullanıcı hesabına **güvenli, geri alınabilir ve devam ettirilebilir** şekilde taşıyan bir PowerShell betiği.

Domain değişikliği, kullanıcı adı yeniden adlandırma, yerel hesaptan domain hesabına geçiş veya profil bozulması sonrası kurtarma gibi senaryolarda elle yapılan (ve genelde hataya çok açık olan) `robocopy` + registry düzenleme + `icacls` adımlarının tamamını tek, denetimli bir akışta yürütür.

> ⚠️ Bu betik **HKLM registry**'sini, **NTFS izinlerini** ve kullanıcı profil klasörlerini doğrudan değiştirir. Üretim ortamında kullanmadan önce test ortamında denemeniz ve `-WhatIf` ile kuru çalıştırma yapmanız şiddetle tavsiye edilir.

---

## İçindekiler

- [Özellikler](#özellikler)
- [Nasıl Çalışır](#nasıl-çalışır)
- [Gereksinimler](#gereksinimler)
- [Kurulum](#kurulum)
- [Parametreler](#parametreler)
- [Kullanım Örnekleri](#kullanım-örnekleri)
- [Migration Fazları](#migration-fazları)
- [Devam Ettirme (Resume) ve Rollback](#devam-ettirme-resume-ve-rollback)
- [Log ve Rapor Dosyaları](#log-ve-rapor-dosyaları)
- [Güvenlik Notları ve Sınırlamalar](#güvenlik-notları-ve-sınırlamalar)
- [1.0 Sürümünde Yapılan Düzeltmeler](#10-sürümünde-yapılan-düzeltmeler)
- [Sorun Giderme](#sorun-giderme)
- [Lisans](#lisans)

---

## Özellikler

- 🔄 **Uçtan uca profil taşıma**: dosya kopyalama, `NTUSER.DAT` içindeki yol/SID referanslarının güncellenmesi, NTFS ACL devri ve `ProfileList` registry güncellemesini tek komutla yapar.
- 💾 **Zorunlu yedekleme**: taşıma başlamadan önce hem profil dosyalarının hem de `ProfileList` registry anahtarının otomatik yedeği alınır.
- ↩️ **Otomatik rollback**: commit aşamasından önce bir hata oluşursa, dosyalar ve registry otomatik olarak yedekten geri yüklenir.
- ▶️ **Resume desteği**: uzun süren taşımalar kesintiye uğrarsa (elektrik kesintisi, oturum kapanması, timeout vb.) `-Resume` ile kaldığı fazdan devam eder.
- 🧪 **`-WhatIf` desteği**: `SupportsShouldProcess` ile tam entegre; hiçbir değişiklik yapmadan tüm planı gösterir.
- 🔒 **Çok katmanlı güvenlik kontrolleri**: kaynak/hedef hesap aktiflik kontrolü, path içi içe geçme kontrolü, hedef ACL doğrulaması, silme öncesi son güvenlik kontrolü.
- 📝 **Detaylı JSON log + JSON durum dosyası + metin rapor** çıktısı.
- 🌍 **Dilden bağımsız**: `SYSTEM` / `Administrators` gibi yerelleştirilmiş hesap adları yerine well-known SID kullanır (Türkçe Windows dahil tüm dillerde çalışır).

## Nasıl Çalışır

Betik, kaynak hesabın profilini hedef hesabın SID'i altında "yeniden doğuracak" şekilde çalışır:

1. Kaynak ve hedef kullanıcı hesaplarının SID'lerini ve mevcut profil yollarını çözümler.
2. Profil klasörünü (varsayılan veya `-DestinationPath` ile belirtilen konuma) `robocopy` ile kopyalar.
3. Kopyalanan `NTUSER.DAT` hive'ını geçici olarak `HKU` altına yükleyip, içindeki eski profil yolu ve eski SID referanslarını (Explorer, Run/RunOnce, App Paths gibi anlamlı anahtarlarla sınırlı olarak) yeni değerlerle değiştirir.
4. Hedef profil klasöründeki NTFS izinlerini hedef hesabın SID'ine devreder; SYSTEM ve Administrators'ın tam erişimini garanti eder.
5. `HKLM\...\ProfileList` altında hedef SID için doğru `ProfileImagePath` değerini yazar ve kaynak SID anahtarını kaldırır.
6. İsteğe bağlı olarak (`-Verify`) hedef profili çok yönlü doğrular.
7. Her şey başarılıysa taşımayı "commit" eder ve (varsayılan olarak, `-KeepSource` verilmediyse) kaynak profil klasörünü siler.

## Gereksinimler

- Windows 10 / 11 veya Windows Server (2016+)
- **Yönetici olarak** (elevated) çalıştırılan PowerShell 5.1 veya üzeri
- Taşınacak kullanıcı hesaplarının **her ikisinin de o an oturum açık olmaması**
- Yeterli disk alanı (kopyalama sırasında hem kaynak hem hedef hem de yedek için alan gerekir)
- `robocopy.exe`, `reg.exe`, `icacls.exe` (Windows'ta varsayılan olarak bulunur)

## Kurulum

Depoyu klonlayın veya `profilemove.ps1` dosyasını indirin:

```powershell
git clone https://github.com/<kullanici-adi>/windows-profile-move.git
cd windows-profile-move
```

Betik imzasız olduğu için, gerekirse yürütme ilkesini o oturum için gevşetin:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Parametreler

| Parametre | Zorunlu | Açıklama |
|---|---|---|
| `-SourceUser` | ✅ | Kaynak hesap. `kullaniciadi` veya `DOMAIN\kullaniciadi` biçiminde. |
| `-TargetUser` | ✅ | Hedef hesap. `kullaniciadi` veya `DOMAIN\kullaniciadi` biçiminde. |
| `-DestinationPath` | ❌ | Hedef profilin taşınacağı özel klasör yolu. Belirtilmezse hedef hesabın mevcut/varsayılan profil yolu kullanılır. |
| `-KeepSource` | ❌ | Belirtilirse kaynak profil silinmez, sadece kopyalanır (klonlama davranışı). |
| `-Force` | ❌ | Hedef profil klasörü zaten varsa üzerine yazılmasına izin verir. |
| `-Backup` | ❌ | Bilgilendirme amaçlı; betik yedeklemeyi **her durumda zorunlu** yapar, bu anahtar sadece niyeti açıkça belirtmek içindir. |
| `-BackupPath` | ❌ | Yedeklerin yazılacağı kök klasör. Varsayılan: `%TEMP%\ProfileMigration\Backup`. |
| `-Verify` | ❌ | Hedef profili (ve son adımda kaynağın gerçekten silindiğini) doğrulayan ek kontrolleri etkinleştirir. |
| `-SkipNTUserUpdate` | ❌ | `NTUSER.DAT` içindeki yol/SID güncellemesini atlar (ör. hive'ı başka bir araçla güncelleyecekseniz). |
| `-Silent` | ❌ | Konsola renkli çıktı basmaz; sadece log dosyasına yazar. |
| `-TimeoutMinutes` | ❌ | Robocopy işlemleri için zaman aşımı (1–1440 dakika arası). Varsayılan: 120. |
| `-Resume` | ❌ | `-StateFile` ile belirtilen kayıtlı durumdan taşımaya devam eder. |
| `-StateFile` | ❌ | Durum (state) JSON dosyasının yolu. Belirtilmezse otomatik oluşturulur ve loglanır. |

Betik `SupportsShouldProcess` desteklediği için standart PowerShell ortak parametreleri de kullanılabilir: `-WhatIf`, `-Confirm`, `-Verbose`.

## Kullanım Örnekleri

### 1. En basit kullanım — aynı makinede iki yerel hesap arasında taşıma

```powershell
.\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new'
```

Kaynak profili, hedef hesabın varsayılan profil konumuna (`C:\Users\aelci.new`) kopyalar, izinleri ve `ProfileList`'i günceller, doğrulama sonrası kaynağı siler.

### 2. Kuru çalıştırma (hiçbir şeyi değiştirmeden planı görme)

```powershell
.\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' -WhatIf
```

Sadece kullanıcı çözümlemesi, güvenlik kontrolleri ve migration raporu gösterilir; disk ve registry'ye hiçbir yazma işlemi yapılmaz.

### 3. Domain hesabından yerel hesaba, özel hedef yol ile

```powershell
.\profilemove.ps1 `
    -SourceUser 'CONTOSO\ali.elci' `
    -TargetUser 'aelci.local' `
    -DestinationPath 'D:\Profiles\aelci.local' `
    -Verify
```

### 4. Kaynağı silmeden, doğrulama açık, ayrıntılı loglama ile klonlama

```powershell
.\profilemove.ps1 `
    -SourceUser 'aelci.old' `
    -TargetUser 'aelci.new' `
    -KeepSource `
    -Verify `
    -Verbose
```

Kaynak profil dokunulmadan kalır; hedefte tam bir kopya oluşturulur ve doğrulanır. Rollback/deneme senaryoları için idealdir.

### 5. Var olan bir hedef profilin üzerine zorla yazma

```powershell
.\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' -Force
```

`-Force` verilmezse ve hedef profil klasörü zaten mevcutsa betik güvenlik amacıyla hata verip durur.

### 6. Özel yedek konumu ve uzun zaman aşımı (büyük profiller için)

```powershell
.\profilemove.ps1 `
    -SourceUser 'aelci.old' `
    -TargetUser 'aelci.new' `
    -BackupPath 'E:\ProfileBackups' `
    -TimeoutMinutes 480
```

### 7. Sessiz mod (otomasyon / zamanlanmış görev için)

```powershell
.\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' -Silent -Verify
$exitCode = $LASTEXITCODE   # 0 = başarılı, 1 = başarısız
```

### 8. Kesintiye uğrayan bir taşımayı devam ettirme

İlk çalıştırmada state dosyasının yolunu not edin (konsolda ve log dosyasında görünür):

```powershell
.\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' `
    -StateFile 'C:\Temp\ProfileMigration\state_20260819_120000.json'
```

Kesinti sonrası (aynı `-StateFile` ile) devam ettirin:

```powershell
.\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' `
    -Resume -StateFile 'C:\Temp\ProfileMigration\state_20260819_120000.json'
```

> `-Resume` ile çalıştırırken `-SourceUser`/`-TargetUser` yine de verilmelidir; asıl kaynak, kayıtlı state dosyasıdır ve zaten tamamlanmış (`COMPLETED`) veya rollback yapılmış (`ROLLBACK`) bir state ile devam ettirme işlemi engellenir.

## Migration Fazları

Betik, her biri state dosyasına kaydedilen sıralı fazlardan geçer:

```
INIT → BACKUP → COPY → TRANSFORM_HIVE → UPDATE_ACL → UPDATE_PROFILELIST
     → (VERIFY_TARGET) → COMMIT → DELETE_SOURCE → (FINAL_VERIFY) → COMPLETED
```

| Faz | Açıklama |
|---|---|
| `INIT` | Kullanıcı/SID çözümlemesi, güvenlik kontrolleri, ilk state kaydı. |
| `BACKUP` | Kaynak profil dosyalarının ve `ProfileList` registry anahtarının yedeklenmesi. |
| `COPY` | `robocopy` ile dosyaların hedef konuma kopyalanması. |
| `TRANSFORM_HIVE` | Hedefteki `NTUSER.DAT` içindeki eski yol/SID referanslarının güncellenmesi. |
| `UPDATE_ACL` | Hedef profildeki NTFS izinlerinin hedef SID'ine devredilmesi. |
| `UPDATE_PROFILELIST` | `HKLM\...\ProfileList` altında hedef kaydın yazılması, kaynak kaydın silinmesi. |
| `VERIFY_TARGET` | (`-Verify` ile) hedef profilin bütünlük/izin/registry doğrulaması. |
| `COMMIT` | Taşımanın geri dönüşü olmayan noktaya işaretlenmesi. |
| `DELETE_SOURCE` | (`-KeepSource` verilmediyse) kaynak profil klasörünün silinmesi. |
| `FINAL_VERIFY` | (`-Verify` ile) son bütünlük kontrolü. |
| `COMPLETED` | Taşıma başarıyla tamamlandı. |

## Devam Ettirme (Resume) ve Rollback

- Her faz **idempotent** şekilde tasarlanmıştır: zaten tamamlanmış bir faz, `-Resume` ile tekrar çalıştırıldığında atlanır.
- `COMMIT` fazından **önce** oluşan bir hata otomatik rollback'i tetikler: kopyalanan hedef dosyalar ve `ProfileList` registry'si yedekten geri yüklenir.
- `COMMIT` fazından **sonra** (özellikle kaynak silindikten sonra) otomatik rollback **bilinçli olarak devre dışıdır** — bu noktada geri almak, kısmen silinmiş bir kaynak ile kısmen taahhüt edilmiş bir hedefi karıştırma riski taşır. Bu durumda log ve yedek klasörü kullanılarak **manuel** müdahale gerekir.
- `ROLLBACK` veya `FAILED` fazında kalmış bir state dosyası ile `-Resume` yapılamaz; betik bilinçli olarak yeni bir taşıma başlatmanızı ister.

## Log ve Rapor Dosyaları

Varsayılan olarak her şey `%TEMP%\ProfileMigration\` altında toplanır:

- `ProfileMove_<tarih_saat>.log` — her satırı JSON olan ayrıntılı işlem günlüğü.
- `state_<tarih_saat>.json` — resume için kullanılan canlı taşıma durumu.
- `MigrationReport_<migration-id>.json` — taşıma sonunda oluşturulan özet rapor.

## Güvenlik Notları ve Sınırlamalar

- Betik yönetici olarak çalıştırılmazsa **hemen** hata verip durur.
- Kaynak/hedef hesap **aktif oturum açmışsa** taşıma başlamaz; ayrıca kaynak profil silinmeden hemen önce bu kontrol **tekrar** yapılır (uzun süren taşımalarda araya oturum açılmasına karşı).
- Hedef ve kaynak profil yollarının iç içe geçmesi (biri diğerinin alt/üst klasörü olması) veya `%SystemRoot%`'un hedef olarak seçilmesi engellenir.
- `NTUSER.DAT` içindeki yol/SID güncellemesi, bilinçli olarak yalnızca anlamlı olan birkaç registry alt anahtarıyla (Explorer, Run, RunOnce, App Paths) sınırlıdır; hive'ın tamamını körlemesine taramaz. Bu, kapsamı daraltarak beklenmeyen yan etkileri azaltır ama profildeki **her** uygulama-özel yol referansını güncellemez.
- Betik, tüm profili değil yalnızca `NTFS izinlerini yeniden inşa eder` — `robocopy /COPY:DAT` bilinçli olarak orijinal ACL'leri kopyalamaz; izinler `Update-ProfileACL` tarafından SID bazlı olarak yeniden kurulur.
- Bu bir **Microsoft User State Migration Tool (USMT)** alternatifi değildir; uygulama ayarları, lisans aktivasyonları veya bazı üçüncü parti yazılımların kullanıcı-özel kayıtları taşınmayabilir. Kritik ortamlarda taşıma sonrası uygulamaları test edin.

## 1.0 Sürümünde Yapılan Düzeltmeler

Bu sürüm, önceki taslak üzerinde yapılan bir kod incelemesi sonucu bulunan ve giderilen sorunları içerir:

1. **Aktiflik tespiti düzeltildi** — `query user` çıktısı SID değil kullanıcı adı içerdiği için, eski kod SID ile eşleştirme yaparak fiilen hiçbir zaman eşleşmiyordu. Artık birincil kontrol olarak `HKEY_USERS` altındaki yüklü hive kontrolü, ikincil olarak da kullanıcı adı bazlı `query user` eşleşmesi kullanılıyor.
2. **Silme öncesi ikinci aktiflik kontrolü eklendi** — `-TimeoutMinutes` 24 saate kadar çıkabildiği için, kaynak profil silinmeden hemen önce kaynak ve hedef hesabın tekrar aktif olup olmadığı yeniden kontrol ediliyor.
3. **`ProfileList` değerleri artık korunuyor** — hedefte daha önce hiç `ProfileList` anahtarı yoksa, `Flags`/`State`/`RefCount` gibi Windows'un profil bütünlüğü için beklediği değerler kaynak anahtarından kopyalanıyor (önceki sürümde sadece `ProfileImagePath` yazılıp bu değerler boş bırakılıyordu).
4. **Regex replacement güvenliği** — `NTUSER.DAT` içindeki yol değiştirme işleminde, hedef yol `$` karakteri içeriyorsa (`$1`, `$&` gibi) regex geri referansı olarak yanlış yorumlanabiliyordu; artık değer literal olarak escape ediliyor.
5. **Dilden bağımsız `icacls` çağrıları** — `SYSTEM` / `Administrators` yerine well-known SID'ler (`S-1-5-18`, `S-1-5-32-544`) kullanılıyor; böylece Türkçe gibi yerelleştirilmiş Windows kurulumlarında izin adımı artık başarısız olmuyor.
6. **Kalıntı ACL temizliği** — hedef profil ağacında kaynak SID'ine ait kalıntı (explicit) izin girdileri, kök klasörle sınırlı kalmadan `icacls /remove:g /T` ile recursive olarak da temizleniyor.

## Sorun Giderme

**"This script must be run from an elevated PowerShell session."**
PowerShell'i "Yönetici olarak çalıştır" ile açın.

**"Target profile already exists... Use -Force."**
Hedef profil klasörü zaten var. Kasıtlıysa `-Force` ekleyin, değilse hedef hesabı/yolu kontrol edin.

**"Source user appears to be active. Log off before migration."**
Kaynak (veya hedef) hesap oturumu kapatılmadan taşıma başlatılamaz. İlgili kullanıcının oturumunu kapatın ve tekrar deneyin.

**Robocopy zaman aşımına uğruyor.**
`-TimeoutMinutes` değerini artırın (maks. 1440) veya `-BackupPath`/hedef yolun daha hızlı bir disk üzerinde olduğundan emin olun.

**Taşıma yarıda kaldı, ne yapmalıyım?**
Konsolda/logda gösterilen `-StateFile` yolunu bulup `-Resume -StateFile <yol>` ile aynı komutu tekrar çalıştırın. State `FAILED` veya `ROLLBACK` fazındaysa, log ve yedek klasörünü (`BackupPath` altında) inceleyip manuel karar verin.

## Lisans

Bu proje mevcut haliyle ("as is"), hiçbir garanti verilmeksizin sunulmaktadır. Üretim ortamında kullanmadan önce kendi test ortamınızda doğrulayın.

---

**Yazar:** ALİ ELÇİ
**Proje:** Windows Profile Move
**Sürüm:** 1.0
