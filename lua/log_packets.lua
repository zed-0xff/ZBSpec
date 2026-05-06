local packets = {
    "AnimalUpdateReliablePacket",
    "AnimalUpdateUnreliablePacket",

    "AddBloodPacket",

    "GlobalObjectsPacket",
    "ScoreboardUpdatePacket",
    "StatePacket",
    "RequestZipListPacket",

    "PlayerDamagePacket",
    "PlayerEffectsPacket",
    "PlayerHealthPacket",
    "PlayerInjuriesPacket",
    "PlayerPacketReliable",
    "PlayerStatsPacket",
    "PlayerXpPacket",

    "PlaySoundPacket",
    "StopSoundPacket",

    "ItemStatsPacket",
    "RecipePacket",
    "StatisticsPacket",
    "SyncClockPacket",
    "WaveSignalPacket",

    "ZombieListPacket",
    "ZombieSynchronizationReliablePacket",
    "ZombieSynchronizationUnreliablePacket",
}

ZombieBuddy.PacketLog.exclude(packets)
ZombieBuddy.PacketLog.enable()
