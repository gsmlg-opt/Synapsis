                                                                     
                                                                                 

/** Runtime configuration for Skill Workshop. */
                            
               
                                       
                            
    
                        
  

export function resolveSkillWorkshopConfig(config                 )                      {
  const raw = config?.skills?.workshop;
  return {
    autonomous: {
      mode: raw?.autonomous?.mode ?? "auto",
      channelNotices: raw?.autonomous?.channelNotices ?? false,
    },
    maxSkillBytes: Math.min(Math.max(raw?.maxSkillBytes ?? 40_000, 1024), 200_000),
  };
}
