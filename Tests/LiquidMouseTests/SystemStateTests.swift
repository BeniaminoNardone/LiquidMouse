import Testing
@testable import LiquidMouse

struct SystemStateTests {
    @Test func recognizesGameCategoriesWithoutGuessingFromNamesOrFullscreen() {
        #expect(SystemState.isGame(category: "public.app-category.games"))
        #expect(SystemState.isGame(category: "public.app-category.action-games"))
        #expect(SystemState.isGame(category: "public.app-category.role-playing-games"))
        #expect(!SystemState.isGame(category: "public.app-category.entertainment"))
        #expect(!SystemState.isGame(category: "public.app-category.developer-tools"))
        #expect(!SystemState.isGame(category: "games"))
        #expect(!SystemState.isGame(category: "some.other.action-games"))
        #expect(!SystemState.isGame(category: nil))
    }
}
