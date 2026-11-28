import AppKit

// MARK: - Profile

extension CatCoatTheme {
    /// 没取名字时顶在头上的品种名
    var breedName: String {
        switch self {
        case .classicBlack: return "小黑猫"
        case .siamese: return "暹罗"
        case .shorthair: return "美短"
        case .orangeWhite: return "橘白"
        }
    }
}

extension CatProfile {
    /// 自己这只猫的名片：设置里的名字、毛色、瞳色、品种、装扮
    static var mine: CatProfile {
        let settings = CatSettings.shared
        let pet = PetLibrary.shared.active
        return CatProfile(name: CatProfile.cleanName(settings.catName),
                          breed: pet?.name ?? settings.coatTheme.breedName,
                          coat: settings.coatTheme.rawValue, eye: settings.eyeTheme.rawValue, petID: pet?.id,
                          accessory: settings.accessory.rawValue)
    }
}
