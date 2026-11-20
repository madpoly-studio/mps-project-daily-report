# report-jira-gitlab

Mỗi sáng 7:30 (thứ 2 – 6) post vào group chat Teams, chia 3 section:
- **Jira – GitLab** (nền xanh lá): task RDG chuyển sang Closed / Resolved / Done *và* có MR merge cùng khoảng (mỗi task kèm các MR của nó)
- **Jira only** (nền vàng — chấp nhận được, vd task GD không cần commit): task done nhưng không có MR merge trong khoảng
- **GitLab only**: MR merge không ghép được task done nào; nếu MR có mã ticket (RDG hoặc project khác như ART) thì ghi kèm trạng thái hiện tại.
  Nền **đỏ** khi có MR không có ticket nào (phạm rule DevOps), nền vàng khi MR nào cũng có ticket.

Đầu card: lời chào theo thứ (8 câu/thứ, đổi theo tuần), 4 chỉ số kèm ▲▼ so với báo cáo trước, sparkline, MVP;
cuối card: bảng đóng góp theo người; thứ 6 có tổng kết tuần. Lịch sử số liệu lưu trong `state.json` (`history`).

Card lớn hơn ~20KB (Teams lặng lẽ bỏ card quá lớn dù webhook vẫn trả 202) được tự tách thành nhiều tin nhắn liên tiếp
(`· phần 1/N`, `phần 2/N`, ..., cách nhau 5 giây), giữ đủ mọi dòng; section nào vừa một tin nhắn thì giữ nguyên,
section quá dài mới chia theo dòng (phần sau ghi "(tiếp)").

Ghép theo mã `RDG-<số>` trong tên source branch hoặc tiêu đề MR (không phân biệt hoa thường).

Khoảng báo cáo là từ lần gửi thành công trước đến 00:00 hôm nay (`state.json`), nên thứ 2 gộp thứ 6 – CN,
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
- **Chỉ gửi group một lần**: id sprint đã gửi được lưu trong `state.json` (`sprintsReported`, giữ 50 id gần nhất).
  `-DryRun` / `-Test` luôn hiện card (không lọc theo danh sách này) và không ghi `state.json`.
- **Không mất card sprint**: card sprint được đọc và gửi **sau** khi daily đã gửi xong, nên lỗi phía sprint không chặn daily.
  Bước sprint xong thì `state.json` ghi mốc `sprintCheckedUntil`; nếu bước sprint lỗi (card báo lỗi ghi rõ "daily ĐÃ gửi"),
  lần chạy sau — chạy lại trong ngày (không `-Force`; daily không gửi lại) hoặc lịch sáng hôm sau — tìm sprint từ mốc đó
  (tối đa 14 ngày) nên vẫn gửi bù. Lần đầu triển khai (chưa có mốc) không gửi lại sprint cũ. Hoặc gửi tay bằng `-SprintId`.
- `-From/-To` gửi group **không** gửi card sprint và không ghi `state.json`; kèm `-DryRun` / `-Test` thì vẫn xem thử được.

## Cấu hình — `.env` (không commit)

| Biến | Ý nghĩa |
|---|---|
| `JIRA_URL`, `JIRA_PERSONAL_TOKEN` | Jira Data Center + Personal Access Token |
| `JIRA_PROJECT` | mặc định `RDG` |
| `JIRA_DONE_STATUSES` | mặc định `Closed,Resolved,Done` |
| `JIRA_BOARD_ID` | (tuỳ chọn) id scrum board cho card tổng kết sprint, nhiều board cách nhau bằng dấu phẩy; để trống thì tự tìm mọi scrum board của `JIRA_PROJECT` (hiện là `357` — R&D Board) |
| `GITLAB_HOST` | `git-gst.mto.zing.vn` |
| `GITLAB_TOKEN` | PAT GitLab (scope `read_api`) — PAT có hạn dùng, hết hạn thì báo cáo lỗi 401, nhớ thay; để trống thì glab dùng biến môi trường `GITLAB_TOKEN` của user nếu có, nếu không thì token từ `glab auth login` (Windows Credential Manager) |
| `GITLAB_PROJECTS` | danh sách `group/repo`, cách nhau bằng dấu phẩy — thêm repo server vào đây |
| `TEAMS_WEBHOOK_URL` | URL của Workflow "Post to a channel when a webhook request is received" |
| `TEAMS_TEST_WEBHOOK_URL` | Workflow của chat test — nhận card `-Test` và mọi card báo lỗi; không có thì chỉ ghi log |

## Lệnh

```powershell
.\daily-report.ps1 -DryRun                                # xem trước, không gửi
.\daily-report.ps1 -Test                                  # gửi vào chat test (TEAMS_TEST_WEBHOOK_URL), không đụng state.json
.\daily-report.ps1 -From 2026-10-27 -To 2026-11-03        # gửi khoảng tuỳ chọn (không đụng state.json, không gửi card sprint)
.\daily-report.ps1 -Force                                 # gửi lại daily hôm nay (card sprint đã gửi thì không gửi lại)
.\daily-report.ps1 -From 2026-11-16 -To 2026-11-17 -DryRun   # xem trước daily + card sprint của sáng mai
.\daily-report.ps1 -SprintId 1884 -DryRun                 # chỉ xem card tổng kết của sprint 1884, bỏ qua daily
.\daily-report.ps1 -SprintId 1895 -Test                   # gửi card tổng kết sprint 1895 vào chat test
.\daily-report.ps1 -SprintId 1895                         # gửi card tổng kết sprint lên group (ghi vào sprintsReported; đã gửi rồi thì bỏ qua)
.\daily-report.ps1 -SprintId 1895 -Force                  # gửi lại card sprint lên group dù đã gửi rồi
.\register-task.ps1                                       # đăng ký lịch 7:30 T2–T6 (card sprint đi kèm lần chạy này)
Start-ScheduledTask 'RDG Daily Report'                    # chạy thử task ngay
Unregister-ScheduledTask 'RDG Daily Report' -Confirm:$false
```

Log mỗi lần chạy: `logs\yyyy-MM-dd.log`, payload gần nhất: `logs\last-payload.json` (card bị tách thì thêm
`last-payload-2.json`, `-3`, ...; `logs\card-for-designer.json` luôn là card đầy đủ chưa tách).
Card sprint (theo id sprint): `logs\sprint-<id>-payload.json` (+ `sprint-<id>-payload-2.json`, ... khi bị tách) và
`logs\sprint-<id>-card-for-designer.json`.
Lỗi khi chạy sẽ được post một card cảnh báo (nội dung lỗi, vị trí trong script, chế độ chạy, đường dẫn log) vào chat test
(`TEAMS_TEST_WEBHOOK_URL`), không bao giờ lên group. Không cấu hình `TEAMS_TEST_WEBHOOK_URL` thì chỉ ghi log.
