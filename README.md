# LookAt

LookAt là trình xem ảnh macOS native, gọn nhẹ, viết bằng Swift + SwiftUI và dùng Liquid Glass của macOS 26.

## Tính năng

- Mở ảnh từ Finder, hộp thoại hoặc kéo thả; GIF động phát đúng thời gian từng frame và số vòng lặp.
- Lăn bánh xe / trackpad để zoom tại vị trí con trỏ.
- Kéo chuột trái hoặc chuột giữa để di chuyển riêng ảnh, không kéo cửa sổ.
- Canvas Core Animation GPU-backed, cập nhật theo từng sự kiện chuột/trackpad, không đặt giới hạn 60 Hz cho thao tác. Tần số hiển thị thực tế phụ thuộc màn hình và macOS.
- Hai lần bấm để đổi giữa vừa cửa sổ và kích thước thật.
- Xoay trái/phải, tự vừa theo chiều ngang hoặc dọc, 100%, chuyển ảnh tức thì trong cùng thư mục.
- Toolbar sát mép trên kiểu Finder; không có bảng trạng thái phía dưới.
- Cửa sổ đơn, không tạo thanh tab khi mở ảnh bằng Finder/Open With.
- Menu chuột phải: Sao chép, Mở bằng, Mở thư mục, Thông tin và Cài Đặt.
- Vùng trống trên hàng toolbar có thể kéo để di chuyển cửa sổ; double-click để phóng cửa sổ theo hành vi thanh tiêu đề macOS.
- Giới hạn thu nhỏ ở 70% so với mức tự vừa.
- Tên dài được cắt ở giữa để luôn nhìn thấy phần mở rộng tệp.
- Pan giữ ít nhất một nửa diện tích có thể nhìn thấy, kể cả khi kéo chéo về góc cửa sổ.
- Ảnh lớn dùng preview theo cửa sổ (tối đa 3072 px), tái sử dụng tác vụ prefetch ảnh trước/sau và chỉ nạp full-resolution khi zoom trên 110%.
- Khi mở lạnh một ảnh rất lớn, LookAt khởi chạy giải mã trước metadata và không để màn hình chào “Mở một bức ảnh” lóe lên trong lúc chờ preview.
- GIF nhiều frame dùng playback GPU và ngân sách bộ nhớ riêng; prefetch chỉ giữ frame đầu để không làm nặng khi chuyển ảnh.
- Chế độ kích thước thật dùng full-resolution, ánh xạ 1 pixel ảnh vào 1 pixel vật lý màn hình Retina và tắt nội suy từ mức 1:1 trở lên.
- Đọc metadata và quét thư mục ở nền. Tối đa một tác vụ giải mã ảnh đang xem và một tác vụ tải trước; tác vụ cũ được hủy khi chuyển ảnh.
- GIF hiện frame đầu trước, sau đó nạp animation; kết quả tải chậm không ghi đè ảnh gốc đã được nạp khi zoom.
- Khi cần thêm thời gian giải mã ảnh gốc, dòng thông tin hiện “Đang tải pixel gốc…”.
- Mở lại ảnh từ Finder/kéo thả luôn đọc lại tệp để nhận các thay đổi từ phần mềm chỉnh sửa.
- Cài Đặt có nút gán LookAt làm ứng dụng mặc định cho PNG, JPEG và các định dạng ảnh phổ biến bằng API công khai của macOS.
- Phím tắt: `←` / `→`, `⌘0`, `⌘1`, `⌘+`, `⌘-`, `[` và `]`.

## Build

Yêu cầu macOS 26 và Xcode 26.

Phiên bản phát hành: **1.0** (build 2), bỏ nhãn beta theo yêu cầu chủ dự án sau đợt rà soát và kiểm thử ổn định.

```sh
./scripts/build_app.sh
```

Ứng dụng và file ZIP sẽ nằm trong thư mục `outputs`.

Tạo bộ cài DMG có lối tắt kéo ứng dụng vào `/Applications`:

```sh
./scripts/build_installer.sh
```

Kết quả: `outputs/LookAt-1.0.dmg`, ứng dụng, ZIP ứng dụng và `LookAt-Source.zip` có cả mã nguồn lẫn kiểm thử. Bundle được ký ad-hoc và kiểm tra chữ ký; chưa ký Developer ID/notarize.

Chạy bộ kiểm tra ảnh lớn, GIF, điều hướng, ảnh 16-bit và canvas Retina:

```sh
zsh scripts/test.sh
```

Chi tiết phạm vi kiểm tra và giới hạn đo lường: [VALIDATION.md](VALIDATION.md).

## Đặt làm trình xem mặc định

Trong Finder, chọn một ảnh → **Get Info** → **Open with: LookAt** → **Change All…**. macOS quản lý ứng dụng mặc định riêng cho từng loại tệp, nên có thể cần lặp lại cho PNG, JPEG và HEIC.
