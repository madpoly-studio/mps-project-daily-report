# report-jira-gitlab

Mỗi sáng 7:30 (thứ 2 – 6) post báo cáo của từng project vào channel Teams của project đó (mỗi project một task
Task Scheduler, một file cấu hình, một state riêng — xem [Nhiều project](#nhiều-project)). Card chia 3 section
(ví dụ dưới đây với project DG):
- **Jira – GitLab** (nền xanh lá): task DG chuyển sang Closed / Resolved / Done *và* có MR merge cùng khoảng (mỗi task kèm các MR của nó)
- **Jira only** (nền vàng — chấp nhận được, vd task GD không cần commit): task done nhưng không có MR merge trong khoảng
- **GitLab only**: MR merge không ghép được task done nào; nếu MR có mã ticket (DG hoặc project khác như ART) thì ghi kèm trạng thái hiện tại.
  Nền **đỏ** khi có MR không có ticket nào (phạm rule DevOps), nền vàng khi MR nào cũng có ticket.

Đầu card: lời chào theo thứ (8 câu/thứ, đổi theo tuần), 4 chỉ số kèm ▲▼ so với báo cáo trước, sparkline, MVP;
cuối card: bảng đóng góp theo người; thứ 6 có tổng kết tuần. Lịch sử số liệu lưu trong `state\<KEY>.json` (`history`).

Card lớn hơn ~20KB (Teams lặng lẽ bỏ card quá lớn dù webhook vẫn trả 202) được tự tách thành nhiều tin nhắn liên tiếp
(`· phần 1/N`, `phần 2/N`, ..., cách nhau 5 giây), giữ đủ mọi dòng; section nào vừa một tin nhắn thì giữ nguyên,
section quá dài mới chia theo dòng (phần sau ghi "(tiếp)").

Ghép theo mã `<JIRA_PROJECT>-<số>` (vd `DG-123`) trong tên source branch hoặc tiêu đề MR (không phân biệt hoa thường).

Khoảng báo cáo là từ lần gửi thành công trước đến 00:00 hôm nay (`state\<KEY>.json`), nên thứ 2 gộp thứ 6 – CN,
và nếu máy tắt một hôm thì lần chạy sau tự gộp ngày bị lỡ.

## Card tổng kết sprint

Sáng hôm sau khi sprint kết thúc, ngay sau card daily là một card **tổng kết sprint** (vd sprint kết thúc 16:00 ngày 16/11
→ 7:30 ngày 17/11 nhận card daily rồi tới card sprint; sprint kết thúc thứ 6 thì nhận vào sáng thứ 2).

- **Khi nào gửi**: thời điểm kết thúc sprint = sớm hơn giữa `completeDate` (team hay đóng sprint sớm) và `endDate`.
  Lần chạy nào có khoảng báo cáo chứa thời điểm đó thì gửi card của sprint đó. Chỉ xét sprint `active` / `closed` thuộc
  scrum board của project (`JIRA_BOARD_ID`, để trống thì tự tìm mọi scrum board của `JIRA_PROJECT`).
- **Nội dung**: tên sprint + ngày bắt đầu – kết thúc, mục tiêu sprint (nếu có), chỉ số (tổng task, hoàn thành, chưa xong,
  tỉ lệ hoàn thành, số thành viên), MVP sprint, rồi từng thành viên với danh sách task: ✅ đã xong trước, ⏳ chưa xong
  (kèm trạng thái). Task chưa gán người nằm cuối. Không ghép MR, không link — chỉ để tổng kết.
  Task "hoàn thành" = trạng thái nằm trong `JIRA_DONE_STATUSES` hoặc thuộc nhóm trạng thái done của Jira.
  Người có hơn 40 task được chia thành nhiều khối (`(tiếp)`) để card dài vẫn tách tin nhắn được.
- **Chỉ gửi group một lần**: id sprint đã gửi được lưu trong `state\<KEY>.json` (`sprintsReported`, giữ 50 id gần nhất).
  `-DryRun` / `-Test` luôn hiện card (không lọc theo danh sách này) và không ghi `state\<KEY>.json`.
- **Không mất card sprint**: card sprint được đọc và gửi **sau** khi daily đã gửi xong, nên lỗi phía sprint không chặn daily.
  Bước sprint xong thì `state\<KEY>.json` ghi mốc `sprintCheckedUntil`; nếu bước sprint lỗi (card báo lỗi ghi rõ "daily ĐÃ gửi"),
  lần chạy sau — chạy lại trong ngày (không `-Force`; daily không gửi lại) hoặc lịch sáng hôm sau — tìm sprint từ mốc đó
  (tối đa 14 ngày) nên vẫn gửi bù. Lần đầu triển khai (chưa có mốc) không gửi lại sprint cũ. Hoặc gửi tay bằng `-SprintId`.
- `-From/-To` gửi group **không** gửi card sprint và không ghi `state\<KEY>.json`; kèm `-DryRun` / `-Test` thì vẫn xem thử được.

## Nhiều project

Mỗi lần chạy báo cáo cho **một** project, chọn bằng tham số bắt buộc `-Project <KEY>` (chữ, số, `_`, `-`).
Mỗi project gửi vào channel Teams riêng (`TEAMS_WEBHOOK_URL` trong file của project), có state, log và task lịch riêng.

```text
.env                        # cấu hình dùng chung (không commit) — mẫu: .env.sample
projects\
    example.env.sample      # mẫu cấu hình riêng của project (commit)
    DG.env                  # cấu hình riêng project DG (không commit)
    ART.env                 # ...
state\
    DG.json                 # state của DG (khoảng báo cáo, history, sprint đã gửi)
logs\
    DG\                     # log + payload của DG (yyyy-MM-dd.log, last-payload.json, sprint-*.json, ...)
```

Thêm project mới (vd `ART`):

1. Copy `projects\example.env.sample` thành `projects\ART.env`, điền `GITLAB_PROJECTS`, `TEAMS_WEBHOOK_URL`
   (tạo theo [Tạo URL webhook Teams](#tạo-url-webhook-teams-workflows))
   và `JIRA_PROJECT` / `JIRA_BOARD_ID` / `JIRA_DONE_STATUSES` nếu cần.
2. Xem thử: `.\daily-report.ps1 -Project ART -DryRun` (có thể thêm `-Test` thay cho `-DryRun` để gửi vào chat test).
3. Đăng ký lịch: `.\register-task.ps1 -Project ART` (task `ART Daily Report`).

Thiếu `projects\<KEY>.env` thì script báo lỗi và liệt kê các project có sẵn.
Card báo lỗi của mọi project đều vào chat test chung, tiêu đề có tiền tố `[<KEY>]` (vd `⚠️ [ART] Daily report bị lỗi`).
Mã project được chuyển thành chữ hoa (`-Project art` = `-Project ART`).

### Chuyển từ bản 1 project

Bản cũ dùng `state.json` ở thư mục gốc, để mọi key trong `.env` và có task `RDG Daily Report`
(project Jira RDG nay đã đổi mã thành DG). Trên máy đang chạy bản cũ:

1. `Move-Item state.json state\DG.json` — giữ history (xu hướng, sparkline, tổng kết tuần) và các sprint đã gửi.
   Còn `state.json` cũ mà chưa có `state\<KEY>.json` thì script báo lỗi.
2. Chuyển `JIRA_PROJECT`, `JIRA_BOARD_ID`, `GITLAB_PROJECTS`, `TEAMS_WEBHOOK_URL` (và `JIRA_DONE_STATUSES` nếu muốn riêng)
   từ `.env` sang `projects\DG.env`. Bốn key đầu mà còn trong `.env` thì script báo lỗi, để project khác không lặng lẽ
   dùng webhook / repo / board của DG.
3. `Unregister-ScheduledTask 'RDG Daily Report' -Confirm:$false` rồi `.\register-task.ps1 -Project DG`.
   Task cũ chạy không có `-Project` sẽ lỗi ngay khi khởi động: không có log, không có card lỗi,
   chỉ thấy `LastTaskResult` khác 0.
4. (tuỳ chọn) Xoá log cũ ở `logs\*.log`, `logs\*.json`; log mới nằm trong `logs\<KEY>\`.

## Cấu hình

Đọc `.env` (chung) trước, rồi `projects\<KEY>.env` ghi đè: key nào có trong file project (kể cả để trống) đều thắng
key cùng tên trong `.env`. Key tuỳ chọn không dùng thì để dạng comment (`# KEY=...`). Comment phải nằm trên dòng riêng.
`JIRA_PROJECT`, `JIRA_BOARD_ID`, `GITLAB_PROJECTS`, `TEAMS_WEBHOOK_URL` chỉ được khai báo trong file project (có trong
`.env` thì báo lỗi); `GITLAB_PROJECTS` bắt buộc, `TEAMS_WEBHOOK_URL` bắt buộc khi gửi group.
`JIRA_DONE_STATUSES` có thể đặt trong `.env` làm mặc định chung.

### `.env` — dùng chung (không commit, mẫu `.env.sample`)

| Biến | Ý nghĩa |
|---|---|
| `JIRA_URL`, `JIRA_PERSONAL_TOKEN` | Jira Data Center + Personal Access Token |
| `GITLAB_HOST` | `git-gst.mto.zing.vn` |
| `GITLAB_TOKEN` | PAT GitLab (scope `read_api`) — PAT có hạn dùng, hết hạn thì báo cáo lỗi 401, nhớ thay; để trống thì glab dùng biến môi trường `GITLAB_TOKEN` của user nếu có, nếu không thì token từ `glab auth login` (Windows Credential Manager) |
| `TEAMS_TEST_WEBHOOK_URL` | Workflow của chat test — nhận card `-Test` và mọi card báo lỗi (của mọi project); không có thì chỉ ghi log |

### `projects\<KEY>.env` — riêng từng project (không commit, mẫu `projects\example.env.sample`)

| Biến | Ý nghĩa |
|---|---|
| `JIRA_PROJECT` | (tuỳ chọn) mã project Jira; không khai báo thì mặc định là `<KEY>` |
| `JIRA_BOARD_ID` | (tuỳ chọn) id scrum board cho card tổng kết sprint, nhiều board cách nhau bằng dấu phẩy; không khai báo thì tự tìm mọi scrum board của `JIRA_PROJECT` (DG hiện là `357`) |
| `GITLAB_PROJECTS` | danh sách `group/repo`, cách nhau bằng dấu phẩy — thêm repo server vào đây |
| `TEAMS_WEBHOOK_URL` | URL Workflow "Post to a channel when a webhook request is received" của channel Teams nhận báo cáo project này (xem [Tạo URL webhook Teams](#tạo-url-webhook-teams-workflows)) |
| `JIRA_DONE_STATUSES` | (tuỳ chọn) mặc định `Closed,Resolved,Done` |

### Tạo URL webhook Teams (Workflows)

Script post card qua Teams **Workflows** (Power Automate), không dùng Incoming Webhook (connector cũ đã bị Microsoft ngừng).
Mỗi channel / chat nhận báo cáo cần một workflow riêng, và mỗi workflow có một URL riêng.

**Channel của project → `TEAMS_WEBHOOK_URL` trong `projects\<KEY>.env`**

1. Trong Teams, mở channel sẽ nhận báo cáo, bấm **⋯** (More options) cạnh tên channel → **Workflows**.
2. Chọn template **Post to a channel when a webhook request is received**. Ở một số bản Teams, template này có tên
   *Send webhook alerts to a channel*.
3. Đặt tên dễ nhận ra, vd `Daily report DG`. Kiểm tra kết nối Microsoft Teams đã đăng nhập (dấu ✓), rồi bấm **Next**.
4. Chọn **Team** và **Channel** (mặc định là channel đang mở), rồi bấm **Add workflow**.
5. Copy URL hiện ra (dạng `https://...logic.azure.com/...` hoặc `https://...powerplatform.com/...`, có tham số `sig=`)
   và dán vào `TEAMS_WEBHOOK_URL=` trong `projects\<KEY>.env`.

**Chat test → `TEAMS_TEST_WEBHOOK_URL` trong `.env`** (một URL dùng chung cho mọi project)

1. Mở chat sẽ nhận card test và card lỗi, ví dụ chat riêng với bot *Workflows*/*Flow bot* hoặc group chat nhỏ.
   Bấm **⋯** → **Workflows**. Nếu chat không có mục này, mở app **Workflows** ở thanh bên trái.
2. Chọn template **Post to a chat when a webhook request is received** (hoặc *Send webhook alerts to a chat*).
3. Đặt tên, bấm **Next**, chọn chat, rồi bấm **Add workflow**. Copy URL vào `TEAMS_TEST_WEBHOOK_URL=` trong `.env`.

**Kiểm tra URL mới.** Lệnh `-Test` chỉ gửi vào chat test. Muốn thử URL của channel mà không gửi báo cáo thật,
hãy post một card nhỏ:

```powershell
$url = '<URL vừa copy>'
$card = @{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'
           body = @(@{ type = 'TextBlock'; text = 'Test webhook daily report'; wrap = $true }) }
$body = @{ type = 'message'; attachments = @(@{ contentType = 'application/vnd.microsoft.card.adaptive'; content = $card }) } |
    ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
```

Lưu ý:
- **URL là bí mật.** Ai có URL đều post được vào channel. Chỉ để URL trong `.env` / `projects\*.env`, không commit,
  không dán vào chat. Nếu lộ URL, xoá workflow (app Workflows → workflow → **Delete**) rồi tạo workflow mới.
- **Giữ nguyên bước "Post card in a chat or channel" của template.** Script gửi đúng định dạng template chờ:
  `{ type: "message", attachments: [ { contentType: "application/vnd.microsoft.card.adaptive", content: <card> } ] }`.
  Bước này lặp qua từng attachment.
- **Workflow chạy dưới tài khoản người tạo.** Nếu tài khoản đó bị khoá, mất license hoặc nghỉ việc, webhook vẫn trả 202
  nhưng không có tin nhắn nào. Nên tạo workflow bằng tài khoản dùng lâu dài, và thêm người khác làm co-owner trong
  Power Automate.
- **Webhook trả 202 mà channel không có tin nhắn:** xem **Run history** của workflow (app Workflows hoặc
  make.powerautomate.com) để biết lỗi. Card quá lớn bị bỏ âm thầm đã được script tự tách (xem đầu README).
  Với **private channel**, nếu Flow bot không post được thì đổi *Post as* của bước post card sang *User*.

## Lệnh

```powershell
.\daily-report.ps1 -Project DG -DryRun                   # xem trước, không gửi
.\daily-report.ps1 -Project DG -Test                     # gửi vào chat test (TEAMS_TEST_WEBHOOK_URL), không đụng state\DG.json
.\daily-report.ps1 -Project DG -From 2026-10-27 -To 2026-11-03   # gửi khoảng tuỳ chọn (không đụng state, không gửi card sprint)
.\daily-report.ps1 -Project DG -Force                    # gửi lại daily hôm nay (card sprint đã gửi thì không gửi lại)
.\daily-report.ps1 -Project DG -From 2026-11-16 -To 2026-11-17 -DryRun   # xem trước daily + card sprint của sáng mai
.\daily-report.ps1 -Project DG -SprintId 1884 -DryRun    # chỉ xem card tổng kết của sprint 1884, bỏ qua daily
.\daily-report.ps1 -Project DG -SprintId 1895 -Test      # gửi card tổng kết sprint 1895 vào chat test
.\daily-report.ps1 -Project DG -SprintId 1895            # gửi card tổng kết sprint lên group (ghi vào sprintsReported; đã gửi rồi thì bỏ qua)
.\daily-report.ps1 -Project DG -SprintId 1895 -Force     # gửi lại card sprint lên group dù đã gửi rồi
.\register-task.ps1 -Project DG                          # đăng ký lịch 7:30 T2–T6, task 'DG Daily Report' (card sprint đi kèm lần chạy này)
Start-ScheduledTask 'DG Daily Report'                    # chạy thử task ngay
Unregister-ScheduledTask 'DG Daily Report' -Confirm:$false
```

Log mỗi lần chạy: `logs\<KEY>\yyyy-MM-dd.log`, payload gần nhất: `logs\<KEY>\last-payload.json` (card bị tách thì thêm
`last-payload-2.json`, `-3`, ...; `logs\<KEY>\card-for-designer.json` luôn là card đầy đủ chưa tách).
Card sprint (theo id sprint): `logs\<KEY>\sprint-<id>-payload.json` (+ `sprint-<id>-payload-2.json`, ... khi bị tách) và
`logs\<KEY>\sprint-<id>-card-for-designer.json`.
Lỗi khi chạy (kể cả lỗi đọc cấu hình) sẽ được post một card cảnh báo (nội dung lỗi, vị trí trong script, chế độ chạy,
đường dẫn log) vào chat test (`TEAMS_TEST_WEBHOOK_URL`), không bao giờ lên group. Không cấu hình `TEAMS_TEST_WEBHOOK_URL`
thì chỉ ghi log.
