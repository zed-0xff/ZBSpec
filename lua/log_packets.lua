local packets = {
    "AnimalUpdateReliablePacket",
    "AnimalUpdateUnreliablePacket",

    "AddBloodPacket",

    "GlobalObjectsPacket",

    "PlayerDamagePacket",
    "PlayerEffectsPacket",
    "PlayerHealthPacket",
    "PlayerInjuriesPacket",
    "PlayerPacketReliable",
    "PlayerStatsPacket",
    "PlayerXpPacket",

    "PlaySoundPacket",
    "StopSoundPacket",

    "RecipePacket",
    "StatisticsPacket",
    "SyncClockPacket",
    "WaveSignalPacket",

    "ZombieListPacket",
    "ZombieSynchronizationReliablePacket",
    "ZombieSynchronizationUnreliablePacket",
}

ZBPacketLog.exclude(packets)
ZBPacketLog.enable()
