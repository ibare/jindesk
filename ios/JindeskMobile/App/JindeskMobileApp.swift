// Jindesk 폰 앱 (docs/MOBILE.md). 맥 앱이 데이터 리포에 올린 학습 페이지를 받아 읽기만 한다.
import SwiftUI

@main
struct JindeskMobileApp: App {
  @State private var model = MobileModel()

  var body: some Scene {
    WindowGroup {
      RootView().environment(model)
    }
  }
}
