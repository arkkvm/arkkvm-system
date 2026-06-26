目标检测模型（根据设备和目标类型选择一个）
object_detection_pfp.data          目标检测（人形、人脸、宠物）轻量模型，输入为640x384(需要配置detModel=ROCKIVA_DET_MODEL_PFP)
object_detection_pfp_512x288.data  目标检测（人形、人脸、宠物）轻量模型，输入为512x288适合近距离场景使用(需要配置detModel=ROCKIVA_DET_MODEL_PFP，并模型文件重命名为object_detection_pfp.data)
object_detection_pfp_896x512.data  目标检测（人形、人脸、宠物）轻量模型，输入为896x512适合人脸抓拍场景使用(需要配置detModel=ROCKIVA_DET_MODEL_PFP，并模型文件重命名为object_detection_pfp.data)
object_detection_pfcp.data         目标检测（人形、人脸、机动车、宠物）轻量模型，输入为640x384（需要配置detModel=ROCKIVA_DET_MODEL_PFCP）


