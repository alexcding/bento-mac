/// Everything a view model can report upward, one case per domain. Each coordinator handles the
/// cases it owns.
public enum Action {
  case sidebar(SidebarViewModel.Action)
  case feed(FeedViewModel.Action)
  case channelSettings(ChannelSettingsViewModel.Action)
}
