// SPDX-License-Identifier: GPL-2.0
/* Author: Dan Scally <djrscally@gmail.com> */

#include <linux/acpi.h>
#include <acpi/acpi_bus.h>
#include <linux/cleanup.h>
#include <linux/device.h>
#include <linux/dmi.h>
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/mei_cl_bus.h>
#include <linux/notifier.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/property.h>
#include <linux/string.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

#include <media/ipu-bridge.h>
#include <media/v4l2-fwnode.h>

#define ADEV_DEV(adev) ACPI_PTR(&((adev)->dev))

/*
 * 92335fcf-3203-4472-af93-7b4453ac29da
 *
 * Used to build MEI CSI device name to lookup MEI CSI device by
 * device_find_child_by_name().
 */
#define MEI_CSI_UUID							\
	UUID_LE(0x92335FCF, 0x3203, 0x4472,				\
		0xAF, 0x93, 0x7B, 0x44, 0x53, 0xAC, 0x29, 0xDA)

/*
 * IVSC device name
 *
 * Used to match IVSC device by ipu_bridge_match_ivsc_dev()
 */
#define IVSC_DEV_NAME "intel_vsc"

/*
 * Extend this array with ACPI Hardware IDs of devices known to be working
 * plus the number of link-frequencies expected by their drivers, along with
 * the frequency values in hertz. This is somewhat opportunistic way of adding
 * support for this for now in the hopes of a better source for the information
 * (possibly some encoded value in the SSDB buffer that we're unaware of)
 * becoming apparent in the future.
 *
 * Do not add an entry for a sensor that is not actually supported.
 *
 * Please keep the list sorted by ACPI HID.
 */
static const struct ipu_sensor_config ipu_supported_sensors[] = {
	/* Himax HM11B1 */
	IPU_SENSOR_CONFIG("HIMX11B1", 1, 384000000),
	/* Himax HM2170 */
	IPU_SENSOR_CONFIG("HIMX2170", 1, 384000000),
	/* Himax HM2172 */
	IPU_SENSOR_CONFIG("HIMX2172", 1, 384000000),
	/* GalaxyCore GC0310 */
	IPU_SENSOR_CONFIG("INT0310", 1, 55692000),
	/* Omnivision OV5693 */
	IPU_SENSOR_CONFIG("INT33BE", 1, 419200000),
	/* Onsemi MT9M114 */
	IPU_SENSOR_CONFIG("INT33F0", 1, 384000000),
	/* Omnivision OV2740 */
	IPU_SENSOR_CONFIG("INT3474", 1, 180000000),
	/* Omnivision OV5670 */
	IPU_SENSOR_CONFIG("INT3479", 1, 422400000),
	/* Omnivision OV8865 */
	IPU_SENSOR_CONFIG("INT347A", 1, 360000000),
	/* Omnivision OV7251 */
	IPU_SENSOR_CONFIG("INT347E", 1, 319200000),
	/* Hynix Hi-556 */
	IPU_SENSOR_CONFIG("INT3537", 1, 437000000),
	/* Lontium lt6911uxe */
	IPU_SENSOR_CONFIG("INTC10C5", 0),
	/* Omnivision OV01A10 / OV01A1S */
	IPU_SENSOR_CONFIG("OVTI01A0", 1, 400000000),
	IPU_SENSOR_CONFIG("OVTI01AS", 1, 400000000),
	/* Omnivision OV02C10 */
	IPU_SENSOR_CONFIG("OVTI02C1", 1, 400000000),
	/* Omnivision OV02E10 */
	IPU_SENSOR_CONFIG("OVTI02E1", 1, 360000000),
	/* Omnivision ov05c10 */
	IPU_SENSOR_CONFIG("OVTI05C1", 1, 480000000),
	/* Omnivision OV08A10 */
	IPU_SENSOR_CONFIG("OVTI08A1", 1, 500000000),
	/* Omnivision OV08x40 */
	IPU_SENSOR_CONFIG("OVTI08F4", 3, 400000000, 749000000, 800000000),
	/* Omnivision OV13B10 */
	IPU_SENSOR_CONFIG("OVTI13B1", 1, 560000000),
	IPU_SENSOR_CONFIG("OVTIDB10", 1, 560000000),
	/* Omnivision OV2680 */
	IPU_SENSOR_CONFIG("OVTI2680", 1, 331200000),
	/* Omnivision OV8856 */
	IPU_SENSOR_CONFIG("OVTI8856", 3, 180000000, 360000000, 720000000),
	/* Sony IMX471 */
	IPU_SENSOR_CONFIG("SONY471A", 1, 200000000),
	/* Toshiba T4KA3 */
	IPU_SENSOR_CONFIG("XMCC0003", 1, 321468000),
};

/*
 * DMI matches for laptops which have their sensor mounted upside-down
 * without reporting a rotation of 180° in neither the SSDB nor the _PLD.
 */
static const struct dmi_system_id upside_down_sensor_dmi_ids[] = {
	{
		.matches = {
			DMI_EXACT_MATCH(DMI_SYS_VENDOR, "Dell Inc."),
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "XPS 13 9350"),
		},
		.driver_data = "OVTI02C1",
	},
	{
		.matches = {
			DMI_EXACT_MATCH(DMI_SYS_VENDOR, "Dell Inc."),
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "XPS 16 9640"),
		},
		.driver_data = "OVTI02C1",
	},
	{} /* Terminating entry */
};

static const struct ipu_property_names prop_names = {
	.clock_frequency = "clock-frequency",
	.rotation = "rotation",
	.orientation = "orientation",
	.bus_type = "bus-type",
	.data_lanes = "data-lanes",
	.remote_endpoint = "remote-endpoint",
	.link_frequencies = "link-frequencies",
};

static const char * const ipu_vcm_types[] = {
	"ad5823",
	"dw9714",
	"ad5816",
	"dw9719",
	"dw9718",
	"dw9806b",
	"wv517s",
	"lc898122xa",
	"lc898212axb",
};

/*
 * Used to figure out IVSC acpi device by ipu_bridge_get_ivsc_acpi_dev()
 * instead of device and driver match to probe IVSC device.
 */
static const struct acpi_device_id ivsc_acpi_ids[] = {
	{ "INTC1059" },
	{ "INTC1095" },
	{ "INTC100A" },
	{ "INTC10CF" },
};

static struct acpi_device *ipu_bridge_get_ivsc_acpi_dev(struct acpi_device *adev)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(ivsc_acpi_ids); i++) {
		const struct acpi_device_id *acpi_id = &ivsc_acpi_ids[i];
		struct acpi_device *consumer, *ivsc_adev;

		acpi_handle handle = acpi_device_handle(ACPI_PTR(adev));
		for_each_acpi_dev_match(ivsc_adev, acpi_id->id, NULL, -1)
			/* camera sensor depends on IVSC in DSDT if exist */
			for_each_acpi_consumer_dev(ivsc_adev, consumer)
				if (ACPI_PTR(consumer->handle) == handle) {
					acpi_dev_put(consumer);
					return ivsc_adev;
				}
	}

	return NULL;
}

static int ipu_bridge_match_ivsc_dev(struct device *dev, const void *adev)
{
	if (ACPI_COMPANION(dev) != adev)
		return 0;

	if (!sysfs_streq(dev_name(dev), IVSC_DEV_NAME))
		return 0;

	return 1;
}

static struct device *ipu_bridge_get_ivsc_csi_dev(struct acpi_device *adev)
{
	struct device *dev, *csi_dev;
	uuid_le uuid = MEI_CSI_UUID;
	char name[64];

	/* IVSC device on platform bus */
	dev = bus_find_device(&platform_bus_type, NULL, adev,
			      ipu_bridge_match_ivsc_dev);
	if (dev) {
		snprintf(name, sizeof(name), "%s-%pUl", dev_name(dev), &uuid);

		csi_dev = device_find_child_by_name(dev, name);

		put_device(dev);

		return csi_dev;
	}

	return NULL;
}

static int ipu_bridge_check_ivsc_dev(struct ipu_sensor *sensor,
				     struct acpi_device *sensor_adev)
{
	struct acpi_device *adev;
	struct device *csi_dev;

	adev = ipu_bridge_get_ivsc_acpi_dev(sensor_adev);
	if (adev) {
		csi_dev = ipu_bridge_get_ivsc_csi_dev(adev);
		if (!csi_dev) {
			acpi_dev_put(adev);
			dev_err(ADEV_DEV(adev), "Failed to find MEI CSI dev\n");
			return -ENODEV;
		}

		sensor->csi_dev = csi_dev;
		sensor->ivsc_adev = adev;
	}

	return 0;
}

static int ipu_bridge_read_acpi_buffer(struct acpi_device *adev, char *id,
				       void *data, u32 size)
{
	struct acpi_buffer buffer = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *obj;
	acpi_status status;
	int ret = 0;

	status = acpi_evaluate_object(ACPI_PTR(adev->handle),
				      id, NULL, &buffer);
	if (ACPI_FAILURE(status))
		return -ENODEV;

	obj = buffer.pointer;
	if (!obj) {
		dev_err(ADEV_DEV(adev), "Couldn't locate ACPI buffer\n");
		return -ENODEV;
	}

	if (obj->type != ACPI_TYPE_BUFFER) {
		dev_err(ADEV_DEV(adev), "Not an ACPI buffer\n");
		ret = -ENODEV;
		goto out_free_buff;
	}

	if (obj->buffer.length > size) {
		dev_err(ADEV_DEV(adev), "Given buffer is too small\n");
		ret = -EINVAL;
		goto out_free_buff;
	}

	memcpy(data, obj->buffer.pointer, obj->buffer.length);

out_free_buff:
	kfree(buffer.pointer);
	return ret;
}

static u32 ipu_bridge_parse_rotation(struct acpi_device *adev,
				     struct ipu_sensor_ssdb *ssdb)
{
	const struct dmi_system_id *dmi_id;

	dmi_id = dmi_first_match(upside_down_sensor_dmi_ids);
	if (dmi_id && acpi_dev_hid_match(adev, dmi_id->driver_data))
		return 180;

	switch (ssdb->degree) {
	case IPU_SENSOR_ROTATION_NORMAL:
		return 0;
	case IPU_SENSOR_ROTATION_INVERTED:
		return 180;
	default:
		dev_warn(ADEV_DEV(adev),
			 "Unknown rotation %d. Assume 0 degree rotation\n",
			 ssdb->degree);
		return 0;
	}
}

static enum v4l2_fwnode_orientation ipu_bridge_parse_orientation(struct acpi_device *adev)
{
	enum v4l2_fwnode_orientation orientation;
	struct acpi_pld_info *pld = NULL;

	if (!acpi_get_physical_device_location(ACPI_PTR(adev->handle), &pld)) {
		dev_warn(ADEV_DEV(adev), "_PLD call failed, using default orientation\n");
		return V4L2_FWNODE_ORIENTATION_EXTERNAL;
	}

	switch (pld->panel) {
	case ACPI_PLD_PANEL_FRONT:
		orientation = V4L2_FWNODE_ORIENTATION_FRONT;
		break;
	case ACPI_PLD_PANEL_BACK:
		orientation = V4L2_FWNODE_ORIENTATION_BACK;
		break;
	case ACPI_PLD_PANEL_TOP:
	case ACPI_PLD_PANEL_LEFT:
	case ACPI_PLD_PANEL_RIGHT:
	case ACPI_PLD_PANEL_UNKNOWN:
		orientation = V4L2_FWNODE_ORIENTATION_EXTERNAL;
		break;
	default:
		dev_warn(ADEV_DEV(adev), "Unknown _PLD panel val %d\n",
			 pld->panel);
		orientation = V4L2_FWNODE_ORIENTATION_EXTERNAL;
		break;
	}

	ACPI_FREE(pld);
	return orientation;
}

int ipu_bridge_parse_ssdb(struct acpi_device *adev, struct ipu_sensor *sensor)
{
	struct ipu_sensor_ssdb ssdb = {};
	int ret;

	ret = ipu_bridge_read_acpi_buffer(adev, "SSDB", &ssdb, sizeof(ssdb));
	if (ret)
		return ret;

	if (ssdb.vcmtype > ARRAY_SIZE(ipu_vcm_types)) {
		dev_warn(ADEV_DEV(adev), "Unknown VCM type %d\n", ssdb.vcmtype);
		ssdb.vcmtype = 0;
	}

	if (ssdb.lanes > IPU_MAX_LANES) {
		dev_err(ADEV_DEV(adev), "Number of lanes in SSDB is invalid\n");
		return -EINVAL;
	}

	sensor->link = ssdb.link;
	sensor->lanes = ssdb.lanes;
	sensor->mclkspeed = ssdb.mclkspeed;
	sensor->rotation = ipu_bridge_parse_rotation(adev, &ssdb);
	sensor->orientation = ipu_bridge_parse_orientation(adev);

	if (ssdb.vcmtype)
		sensor->vcm_type = ipu_vcm_types[ssdb.vcmtype - 1];

	return 0;
}
EXPORT_SYMBOL_NS_GPL(ipu_bridge_parse_ssdb, "INTEL_IPU_BRIDGE");

static void ipu_bridge_create_fwnode_properties(
	struct ipu_sensor *sensor,
	struct ipu_bridge *bridge,
	const struct ipu_sensor_config *cfg)
{
	struct ipu_property_names *names = &sensor->prop_names;
	struct software_node *nodes = sensor->swnodes;

	sensor->prop_names = prop_names;

	if (sensor->csi_dev) {
		sensor->local_ref[0] =
			SOFTWARE_NODE_REFERENCE(&nodes[SWNODE_IVSC_SENSOR_ENDPOINT]);
		sensor->remote_ref[0] =
			SOFTWARE_NODE_REFERENCE(&nodes[SWNODE_IVSC_IPU_ENDPOINT]);
		sensor->ivsc_sensor_ref[0] =
			SOFTWARE_NODE_REFERENCE(&nodes[SWNODE_SENSOR_ENDPOINT]);
		sensor->ivsc_ipu_ref[0] =
			SOFTWARE_NODE_REFERENCE(&nodes[SWNODE_IPU_ENDPOINT]);

		sensor->ivsc_sensor_ep_properties[0] =
			PROPERTY_ENTRY_U32(names->bus_type,
					   V4L2_FWNODE_BUS_TYPE_CSI2_DPHY);
		sensor->ivsc_sensor_ep_properties[1] =
			PROPERTY_ENTRY_U32_ARRAY_LEN(names->data_lanes,
						     bridge->data_lanes,
						     sensor->lanes);
		sensor->ivsc_sensor_ep_properties[2] =
			PROPERTY_ENTRY_REF_ARRAY(names->remote_endpoint,
						 sensor->ivsc_sensor_ref);

		sensor->ivsc_ipu_ep_properties[0] =
			PROPERTY_ENTRY_U32(names->bus_type,
					   V4L2_FWNODE_BUS_TYPE_CSI2_DPHY);
		sensor->ivsc_ipu_ep_properties[1] =
			PROPERTY_ENTRY_U32_ARRAY_LEN(names->data_lanes,
						     bridge->data_lanes,
						     sensor->lanes);
		sensor->ivsc_ipu_ep_properties[2] =
			PROPERTY_ENTRY_REF_ARRAY(names->remote_endpoint,
						 sensor->ivsc_ipu_ref);
	} else {
		sensor->local_ref[0] =
			SOFTWARE_NODE_REFERENCE(&nodes[SWNODE_IPU_ENDPOINT]);
		sensor->remote_ref[0] =
			SOFTWARE_NODE_REFERENCE(&nodes[SWNODE_SENSOR_ENDPOINT]);
	}

	sensor->dev_properties[0] = PROPERTY_ENTRY_U32(
					sensor->prop_names.clock_frequency,
					sensor->mclkspeed);
	sensor->dev_properties[1] = PROPERTY_ENTRY_U32(
					sensor->prop_names.rotation,
					sensor->rotation);
	sensor->dev_properties[2] = PROPERTY_ENTRY_U32(
					sensor->prop_names.orientation,
					sensor->orientation);
	if (sensor->vcm_type) {
		sensor->vcm_ref[0] =
			SOFTWARE_NODE_REFERENCE(&sensor->swnodes[SWNODE_VCM]);
		sensor->dev_properties[3] =
			PROPERTY_ENTRY_REF_ARRAY("lens-focus", sensor->vcm_ref);
	}

	sensor->ep_properties[0] = PROPERTY_ENTRY_U32(
					sensor->prop_names.bus_type,
					V4L2_FWNODE_BUS_TYPE_CSI2_DPHY);
	sensor->ep_properties[1] = PROPERTY_ENTRY_U32_ARRAY_LEN(
					sensor->prop_names.data_lanes,
					bridge->data_lanes, sensor->lanes);
	sensor->ep_properties[2] = PROPERTY_ENTRY_REF_ARRAY(
					sensor->prop_names.remote_endpoint,
					sensor->local_ref);

	if (cfg->nr_link_freqs > 0)
		sensor->ep_properties[3] = PROPERTY_ENTRY_U64_ARRAY_LEN(
			sensor->prop_names.link_frequencies,
			cfg->link_freqs,
			cfg->nr_link_freqs);

	sensor->ipu_properties[0] = PROPERTY_ENTRY_U32_ARRAY_LEN(
					sensor->prop_names.data_lanes,
					bridge->data_lanes, sensor->lanes);
	sensor->ipu_properties[1] = PROPERTY_ENTRY_REF_ARRAY(
					sensor->prop_names.remote_endpoint,
					sensor->remote_ref);
}

static void ipu_bridge_init_swnode_names(struct ipu_sensor *sensor)
{
	snprintf(sensor->node_names.remote_port,
		 sizeof(sensor->node_names.remote_port),
		 SWNODE_GRAPH_PORT_NAME_FMT, sensor->link);
	snprintf(sensor->node_names.port,
		 sizeof(sensor->node_names.port),
		 SWNODE_GRAPH_PORT_NAME_FMT, 0); /* Always port 0 */
	snprintf(sensor->node_names.endpoint,
		 sizeof(sensor->node_names.endpoint),
		 SWNODE_GRAPH_ENDPOINT_NAME_FMT, 0); /* And endpoint 0 */
	if (sensor->vcm_type) {
		/* append link to distinguish nodes with same model VCM */
		snprintf(sensor->node_names.vcm, sizeof(sensor->node_names.vcm),
			 "%s-%u", sensor->vcm_type, sensor->link);
	}

	if (sensor->csi_dev) {
		snprintf(sensor->node_names.ivsc_sensor_port,
			 sizeof(sensor->node_names.ivsc_sensor_port),
			 SWNODE_GRAPH_PORT_NAME_FMT, 0);
		snprintf(sensor->node_names.ivsc_ipu_port,
			 sizeof(sensor->node_names.ivsc_ipu_port),
			 SWNODE_GRAPH_PORT_NAME_FMT, 1);
	}
}

static void ipu_bridge_init_swnode_group(struct ipu_sensor *sensor)
{
	struct software_node *nodes = sensor->swnodes;

	sensor->group[SWNODE_SENSOR_HID] = &nodes[SWNODE_SENSOR_HID];
	sensor->group[SWNODE_SENSOR_PORT] = &nodes[SWNODE_SENSOR_PORT];
	sensor->group[SWNODE_SENSOR_ENDPOINT] = &nodes[SWNODE_SENSOR_ENDPOINT];
	sensor->group[SWNODE_IPU_PORT] = &nodes[SWNODE_IPU_PORT];
	sensor->group[SWNODE_IPU_ENDPOINT] = &nodes[SWNODE_IPU_ENDPOINT];
	if (sensor->vcm_type)
		sensor->group[SWNODE_VCM] =  &nodes[SWNODE_VCM];

	if (sensor->csi_dev) {
		sensor->group[SWNODE_IVSC_HID] =
					&nodes[SWNODE_IVSC_HID];
		sensor->group[SWNODE_IVSC_SENSOR_PORT] =
					&nodes[SWNODE_IVSC_SENSOR_PORT];
		sensor->group[SWNODE_IVSC_SENSOR_ENDPOINT] =
					&nodes[SWNODE_IVSC_SENSOR_ENDPOINT];
		sensor->group[SWNODE_IVSC_IPU_PORT] =
					&nodes[SWNODE_IVSC_IPU_PORT];
		sensor->group[SWNODE_IVSC_IPU_ENDPOINT] =
					&nodes[SWNODE_IVSC_IPU_ENDPOINT];

		if (sensor->vcm_type)
			sensor->group[SWNODE_VCM] = &nodes[SWNODE_VCM];
	} else {
		if (sensor->vcm_type)
			sensor->group[SWNODE_IVSC_HID] = &nodes[SWNODE_VCM];
	}
}

static void ipu_bridge_create_connection_swnodes(struct ipu_bridge *bridge,
						 struct ipu_sensor *sensor)
{
	struct ipu_node_names *names = &sensor->node_names;
	struct software_node *nodes = sensor->swnodes;

	ipu_bridge_init_swnode_names(sensor);

	nodes[SWNODE_SENSOR_HID] = NODE_SENSOR(sensor->name,
					       sensor->dev_properties);
	nodes[SWNODE_SENSOR_PORT] = NODE_PORT(sensor->node_names.port,
					      &nodes[SWNODE_SENSOR_HID]);
	nodes[SWNODE_SENSOR_ENDPOINT] = NODE_ENDPOINT(
						sensor->node_names.endpoint,
						&nodes[SWNODE_SENSOR_PORT],
						sensor->ep_properties);
	nodes[SWNODE_IPU_PORT] = NODE_PORT(sensor->node_names.remote_port,
					   &bridge->ipu_hid_node);
	nodes[SWNODE_IPU_ENDPOINT] = NODE_ENDPOINT(
						sensor->node_names.endpoint,
						&nodes[SWNODE_IPU_PORT],
						sensor->ipu_properties);

	if (sensor->csi_dev) {
		const char *device_hid = "";

		device_hid = acpi_device_hid(sensor->ivsc_adev);

		snprintf(sensor->ivsc_name, sizeof(sensor->ivsc_name), "%s-%u",
			 device_hid, sensor->link);

		nodes[SWNODE_IVSC_HID] = NODE_SENSOR(sensor->ivsc_name,
						     sensor->ivsc_properties);
		nodes[SWNODE_IVSC_SENSOR_PORT] =
				NODE_PORT(names->ivsc_sensor_port,
					  &nodes[SWNODE_IVSC_HID]);
		nodes[SWNODE_IVSC_SENSOR_ENDPOINT] =
				NODE_ENDPOINT(names->endpoint,
					      &nodes[SWNODE_IVSC_SENSOR_PORT],
					      sensor->ivsc_sensor_ep_properties);
		nodes[SWNODE_IVSC_IPU_PORT] =
				NODE_PORT(names->ivsc_ipu_port,
					  &nodes[SWNODE_IVSC_HID]);
		nodes[SWNODE_IVSC_IPU_ENDPOINT] =
				NODE_ENDPOINT(names->endpoint,
					      &nodes[SWNODE_IVSC_IPU_PORT],
					      sensor->ivsc_ipu_ep_properties);
	}

	nodes[SWNODE_VCM] = NODE_VCM(sensor->node_names.vcm);

	ipu_bridge_init_swnode_group(sensor);
}

/*
 * The actual instantiation must be done from a workqueue to avoid
 * a deadlock on taking list_lock from v4l2-async twice.
 */
struct ipu_bridge_instantiate_vcm_work_data {
	struct work_struct work;
	struct device *sensor;
	char name[16];
	struct i2c_board_info board_info;
};

static void ipu_bridge_instantiate_vcm_work(struct work_struct *work)
{
	struct ipu_bridge_instantiate_vcm_work_data *data =
		container_of(work, struct ipu_bridge_instantiate_vcm_work_data,
			     work);
	struct acpi_device *adev = ACPI_COMPANION(data->sensor);
	struct i2c_client *vcm_client;
	bool put_fwnode = true;
	int ret;

	/*
	 * The client may get probed before the device_link gets added below
	 * make sure the sensor is powered-up during probe.
	 */
	ret = pm_runtime_get_sync(data->sensor);
	if (ret < 0) {
		dev_err(data->sensor, "Error %d runtime-resuming sensor, cannot instantiate VCM\n",
			ret);
		goto out_pm_put;
	}

	/*
	 * Note the client is created only once and then kept around
	 * even after a rmmod, just like the software-nodes.
	 */
	vcm_client = i2c_acpi_new_device_by_fwnode(acpi_fwnode_handle(adev),
						   1, &data->board_info);
	if (IS_ERR(vcm_client)) {
		dev_err(data->sensor, "Error instantiating VCM client: %pe\n",
			vcm_client);
		goto out_pm_put;
	}

	device_link_add(&vcm_client->dev, data->sensor, DL_FLAG_PM_RUNTIME);

	dev_info(data->sensor, "Instantiated %s VCM\n", data->board_info.type);
	put_fwnode = false; /* Ownership has passed to the i2c-client */

out_pm_put:
	pm_runtime_put(data->sensor);
	put_device(data->sensor);
	if (put_fwnode)
		fwnode_handle_put(data->board_info.fwnode);
	kfree(data);
}

int ipu_bridge_instantiate_vcm(struct device *sensor)
{
	struct ipu_bridge_instantiate_vcm_work_data *data;
	struct fwnode_handle *vcm_fwnode;
	struct i2c_client *vcm_client;
	struct acpi_device *adev;
	char *sep;

	adev = ACPI_COMPANION(sensor);
	if (!adev)
		return 0;

	vcm_fwnode = fwnode_find_reference(dev_fwnode(sensor), "lens-focus", 0);
	if (IS_ERR(vcm_fwnode))
		return 0;

	/* When reloading modules the client will already exist */
	vcm_client = i2c_find_device_by_fwnode(vcm_fwnode);
	if (vcm_client) {
		fwnode_handle_put(vcm_fwnode);
		put_device(&vcm_client->dev);
		return 0;
	}

	data = kzalloc_obj(*data);
	if (!data) {
		fwnode_handle_put(vcm_fwnode);
		return -ENOMEM;
	}

	INIT_WORK(&data->work, ipu_bridge_instantiate_vcm_work);
	data->sensor = get_device(sensor);
	snprintf(data->name, sizeof(data->name), "%s-VCM",
		 acpi_dev_name(adev));
	data->board_info.dev_name = data->name;
	data->board_info.fwnode = vcm_fwnode;
	snprintf(data->board_info.type, sizeof(data->board_info.type),
		 "%pfwP", vcm_fwnode);
	/* Strip "-<link>" postfix */
	sep = strchrnul(data->board_info.type, '-');
	*sep = 0;

	queue_work(system_long_wq, &data->work);

	return 0;
}
EXPORT_SYMBOL_NS_GPL(ipu_bridge_instantiate_vcm, "INTEL_IPU_BRIDGE");

static int ipu_bridge_instantiate_ivsc(struct ipu_sensor *sensor)
{
	struct fwnode_handle *fwnode;

	if (!sensor->csi_dev)
		return 0;

	fwnode = software_node_fwnode(&sensor->swnodes[SWNODE_IVSC_HID]);
	if (!fwnode)
		return -ENODEV;

	/*
	 * Balance the kobject_put() that the driver core will do on this
	 * software node when csi_dev is destroyed.
	 *
	 * device_add() -> device_platform_notify() -> software_node_notify()
	 * takes a reference on the swnode behind dev_fwnode(dev), and
	 * device_del() -> software_node_notify_remove() drops it again --
	 * unconditionally, outside the swnode->managed check.
	 *
	 * csi_dev (mei-csi) was already added by the MEI client bus before we
	 * get here, so the add-side get never happened for this node, but the
	 * del-side put still will. The MEI bus destroys and recreates mei-csi
	 * on every bus reset (each s2idle/S4 resume), so without this get the
	 * node loses one reference per resume cycle. INTC10CF-N starts at 3
	 * (itself plus its two port children), so the third resume frees it:
	 * software_node_find_by_name() then returns NULL and isys walking the
	 * fwnode graph hits "refcount_t: addition on 0; use-after-free" in
	 * software_node_graph_get_port_parent(). That is the hang on the
	 * second hibernation.
	 */
	fwnode_handle_get(fwnode);

	set_secondary_fwnode(sensor->csi_dev, fwnode);

	return 0;
}

static void ipu_bridge_unregister_sensors(struct ipu_bridge *bridge)
{
	struct ipu_sensor *sensor;
	unsigned int i;

	for (i = 0; i < bridge->n_sensors; i++) {
		sensor = &bridge->sensors[i];
		software_node_unregister_node_group(sensor->group);
		acpi_dev_put(sensor->adev);
		put_device(sensor->csi_dev);
		acpi_dev_put(sensor->ivsc_adev);
	}
}

static int ipu_bridge_connect_sensor(const struct ipu_sensor_config *cfg,
				     struct ipu_bridge *bridge)
{
	struct fwnode_handle *fwnode, *primary;
	struct ipu_sensor *sensor;
	struct acpi_device *adev = NULL;
	int ret;

	for_each_acpi_dev_match(adev, cfg->hid, NULL, -1) {
		if (!ACPI_PTR(adev->status.enabled))
			continue;

		if (bridge->n_sensors >= IPU_MAX_PORTS) {
			acpi_dev_put(adev);
			dev_err(bridge->dev, "Exceeded available IPU ports\n");
			return -EINVAL;
		}

		sensor = &bridge->sensors[bridge->n_sensors];

		ret = bridge->parse_sensor_fwnode(adev, sensor);
		if (ret)
			goto err_put_adev;

		snprintf(sensor->name, sizeof(sensor->name), "%s-%u",
			 cfg->hid, sensor->link);

		ret = ipu_bridge_check_ivsc_dev(sensor, adev);
		if (ret)
			goto err_put_adev;

		ipu_bridge_create_fwnode_properties(sensor, bridge, cfg);
		ipu_bridge_create_connection_swnodes(bridge, sensor);

		ret = software_node_register_node_group(sensor->group);
		if (ret)
			goto err_put_ivsc;

		fwnode = software_node_fwnode(&sensor->swnodes[
						      SWNODE_SENSOR_HID]);
		if (!fwnode) {
			ret = -ENODEV;
			goto err_free_swnodes;
		}

		sensor->adev = ACPI_PTR(acpi_dev_get(adev));

		primary = acpi_fwnode_handle(adev);
		primary->secondary = fwnode;

		ret = ipu_bridge_instantiate_ivsc(sensor);
		if (ret)
			goto err_free_swnodes;

		dev_info(bridge->dev, "Found supported sensor %s\n",
			 acpi_dev_name(adev));

		bridge->n_sensors++;
	}

	return 0;

err_free_swnodes:
	software_node_unregister_node_group(sensor->group);
err_put_ivsc:
	put_device(sensor->csi_dev);
	acpi_dev_put(sensor->ivsc_adev);
err_put_adev:
	acpi_dev_put(adev);
	return ret;
}

static int ipu_bridge_connect_sensors(struct ipu_bridge *bridge)
{
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(ipu_supported_sensors); i++) {
		const struct ipu_sensor_config *cfg =
			&ipu_supported_sensors[i];

		ret = ipu_bridge_connect_sensor(cfg, bridge);
		if (ret)
			goto err_unregister_sensors;
	}

	return 0;

err_unregister_sensors:
	ipu_bridge_unregister_sensors(bridge);
	return ret;
}

static int ipu_bridge_ivsc_is_ready(void)
{
	struct acpi_device *sensor_adev, *adev;
	struct device *csi_dev;
	bool ready = true;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(ipu_supported_sensors); i++) {
		const struct ipu_sensor_config *cfg =
			&ipu_supported_sensors[i];

		for_each_acpi_dev_match(sensor_adev, cfg->hid, NULL, -1) {
			if (!ACPI_PTR(sensor_adev->status.enabled))
				continue;

			adev = ipu_bridge_get_ivsc_acpi_dev(sensor_adev);
			if (!adev)
				continue;

			csi_dev = ipu_bridge_get_ivsc_csi_dev(adev);
			if (!csi_dev)
				ready = false;

			put_device(csi_dev);
			acpi_dev_put(adev);
		}
	}

	return ready;
}

static int ipu_bridge_check_fwnode_graph(struct fwnode_handle *fwnode)
{
	struct fwnode_handle *endpoint;

	if (IS_ERR_OR_NULL(fwnode))
		return -EINVAL;

	endpoint = fwnode_graph_get_next_endpoint(fwnode, NULL);
	if (endpoint) {
		fwnode_handle_put(endpoint);
		return 0;
	}

	return ipu_bridge_check_fwnode_graph(fwnode->secondary);
}

static DEFINE_MUTEX(ipu_bridge_mutex);

/*
 * After hibernate, mei_restart recreates mei-csi. The IPU graph already
 * exists so ipu_bridge_init early-returns; the new mei-csi is born without
 * a secondary swnode. Attach INTCxxxx-N before/after probe.
 *
 * v1.4 race (2026-09-04): sync reattach during mei_csi_probe could not
 * find the child ("no child") even though that same device was probing.
 * Fix: always schedule deferred reattach+device_attach after early-return
 * so fwnode is set once the failed probe has left the device unbound.
 */
static int ipu_bridge_match_csi_child(struct device *dev, void *data)
{
	struct device **out = data;
	uuid_le uuid = MEI_CSI_UUID;
	char needle[40];

	snprintf(needle, sizeof(needle), "%pUl", &uuid);
	if (!strstr(dev_name(dev), needle))
		return 0;

	*out = get_device(dev);
	return 1;
}

static struct device *ipu_bridge_find_mei_csi(void)
{
	struct device *vsc, *csi_dev;
	uuid_le uuid = MEI_CSI_UUID;
	char csi_name[64];

	vsc = bus_find_device_by_name(&platform_bus_type, NULL, IVSC_DEV_NAME);
	if (!vsc)
		return NULL;

	snprintf(csi_name, sizeof(csi_name), "%s-%pUl", dev_name(vsc), &uuid);
	csi_dev = device_find_child_by_name(vsc, csi_name);
	if (!csi_dev)
		device_for_each_child(vsc, &csi_dev, ipu_bridge_match_csi_child);

	put_device(vsc);
	return csi_dev;
}

static int ipu_bridge_attach_swnode(struct device *csi_dev)
{
	const struct software_node *node;
	struct fwnode_handle *fwnode;
	struct acpi_device *sensor_adev;
	unsigned int i;

	if (dev_fwnode(csi_dev))
		return 0;

	for (i = 0; i < ARRAY_SIZE(ipu_supported_sensors); i++) {
		const struct ipu_sensor_config *cfg =
			&ipu_supported_sensors[i];

		for_each_acpi_dev_match(sensor_adev, cfg->hid, NULL, -1) {
			struct ipu_sensor_ssdb ssdb;
			struct acpi_device *ivsc_adev;
			char ivsc_name[ACPI_ID_LEN + 4];

			if (!ACPI_PTR(sensor_adev->status.enabled))
				continue;

			if (ipu_bridge_read_acpi_buffer(sensor_adev, "SSDB",
							&ssdb, sizeof(ssdb)))
				continue;

			ivsc_adev = ipu_bridge_get_ivsc_acpi_dev(sensor_adev);
			if (!ivsc_adev)
				continue;

			snprintf(ivsc_name, sizeof(ivsc_name), "%s-%u",
				 acpi_device_hid(ivsc_adev), ssdb.link);
			acpi_dev_put(ivsc_adev);

			node = software_node_find_by_name(NULL, ivsc_name);
			if (!node)
				continue;

			fwnode = software_node_fwnode(node);
			/*
			 * Keep the reference that
			 * software_node_find_by_name() took: it balances the
			 * unconditional kobject_put() done by
			 * software_node_notify_remove() when this csi_dev is
			 * destroyed on the next MEI bus reset. See the
			 * comment in ipu_bridge_instantiate_ivsc().
			 */
			set_secondary_fwnode(csi_dev, fwnode);
			pr_err("ipu_bridge: attached %s to %s\n",
			       ivsc_name, dev_name(csi_dev));
			return 0;
		}
	}

	for (i = 0; i < 8; i++) {
		char ivsc_name[16];

		snprintf(ivsc_name, sizeof(ivsc_name), "INTC10CF-%u", i);
		node = software_node_find_by_name(NULL, ivsc_name);
		if (!node)
			continue;

		fwnode = software_node_fwnode(node);
		/* Keep the find_by_name() reference -- see above. */
		set_secondary_fwnode(csi_dev, fwnode);
		pr_err("ipu_bridge: attached %s to %s (fallback)\n",
		       ivsc_name, dev_name(csi_dev));
		return 0;
	}

	pr_err("ipu_bridge: no INTC10CF-N swnode for %s\n",
	       dev_name(csi_dev));
	return -ENOENT;
}

/*
 * After S4 the LJCA i2c client is new and has only the ACPI fwnode —
 * check_hwcfg -EPROBE_DEFER. Putting OVTI02C1-N on ACPI
 * primary->secondary poisons ACPI PM QoS sysfs; the next acpi_dev_pm_detach
 * Oopses (v1.9–1.15). Instantiate a non-ACPI i2c client whose primary
 * fwnode is the software node, and match ov02c10 via i2c_device_id.
 *
 * acpi_get_first_physical_node() takes a get_device. i2c_unregister_device()
 * of that same client runs ACPI unbind, which drops that ref. An extra
 * put_device underflowed: v1.16 inside unregister, v1.17 after it.
 */
static bool ipu_bridge_unregister_acpi_i2c(struct acpi_device *adev,
					   struct i2c_adapter **adapter_out,
					   unsigned short *addr_out)
{
	struct device *pdev = acpi_get_first_physical_node(adev);
	struct i2c_client *old;

	if (!pdev)
		return false;
	old = i2c_verify_client(pdev);
	if (!old) {
		put_device(pdev);
		return false;
	}
	if (adapter_out) {
		*adapter_out = old->adapter;
		get_device(&(*adapter_out)->dev);
	}
	if (addr_out)
		*addr_out = old->addr;
	pr_err("ipu_bridge: unregister ACPI i2c %s\n", dev_name(&old->dev));
	i2c_unregister_device(old);
	return true;
}

static struct i2c_client *
ipu_bridge_new_swnode_sensor(struct acpi_device *adev,
			     const struct software_node *node)
{
	struct i2c_board_info info = { };
	struct fwnode_handle *primary = acpi_fwnode_handle(adev);
	struct i2c_client *nclient;
	struct i2c_adapter *adapter = NULL;

	strscpy(info.type, "ov02c10", sizeof(info.type));
	/*
	 * Use .fwnode, not .swnode. With .swnode the i2c core takes ownership
	 * through device_add_software_node() and unregisters the node when the
	 * client goes away. This node is not ours to free: it belongs to the
	 * graph ipu_bridge built at boot, and isys still walks it. Freeing it
	 * on the second freeze left isys_notifier_init() doing kobject_get()
	 * on dead memory:
	 *   refcount_t: addition on 0; use-after-free
	 *   kobject_get / software_node_graph_get_port_parent
	 *   fwnode_graph_get_endpoint_by_id / isys_notifier_init
	 * .fwnode only points the client at the node and leaves it alone.
	 */
	info.fwnode = software_node_fwnode(node);

	if (ipu_bridge_unregister_acpi_i2c(adev, &adapter, &info.addr))
		pr_err("ipu_bridge: drop ACPI i2c before swnode client\n");

	acpi_device_set_enumerated(adev);

	if (adapter) {
		nclient = i2c_new_client_device(adapter, &info);
		put_device(&adapter->dev);
		return nclient;
	}

	if (!primary)
		return ERR_PTR(-ENODEV);
	return i2c_acpi_new_device_by_fwnode(primary, 0, &info);
}

static void ipu_bridge_reattach_sensor_swnodes(void)
{
	struct acpi_device *adev;
	unsigned int i, link;

	for (i = 0; i < ARRAY_SIZE(ipu_supported_sensors); i++) {
		const struct ipu_sensor_config *cfg =
			&ipu_supported_sensors[i];

		for_each_acpi_dev_match(adev, cfg->hid, NULL, -1) {
			const struct software_node *node;
			struct fwnode_handle *swnode_fw;
			struct i2c_client *existing, *nclient;
			char name[ACPI_ID_LEN + 4];
			bool found = false;

			if (!ACPI_PTR(adev->status.enabled))
				continue;

			for (link = 0; link < 8; link++) {
				snprintf(name, sizeof(name), "%s-%u",
					 cfg->hid, link);
				node = software_node_find_by_name(NULL, name);
				if (!node)
					continue;
				swnode_fw = software_node_fwnode(node);
				found = true;
				break;
			}
			if (!found)
				continue;

			existing = i2c_find_device_by_fwnode(swnode_fw);
			if (existing) {
				if (!existing->dev.driver) {
					int ret;

					pr_err("ipu_bridge: device_attach swnode sensor %s\n",
					       dev_name(&existing->dev));
					ret = device_attach(&existing->dev);
					pr_err("ipu_bridge: sensor device_attach -> %d\n",
					       ret);
				}
				put_device(&existing->dev);
				continue;
			}

			nclient = ipu_bridge_new_swnode_sensor(adev, node);
			if (IS_ERR(nclient))
				pr_err("ipu_bridge: swnode i2c client failed: %ld\n",
				       PTR_ERR(nclient));
			else
				pr_err("ipu_bridge: swnode i2c client %s companion=%s\n",
				       dev_name(&nclient->dev),
				       ACPI_COMPANION(&nclient->dev) ?
				       acpi_dev_name(ACPI_COMPANION(&nclient->dev)) :
				       "none");
		}
	}
}

static void ipu_bridge_sensor_retry(struct work_struct *work);
static DECLARE_DELAYED_WORK(ipu_bridge_sensor_dwork,
			    ipu_bridge_sensor_retry);

static bool ipu_bridge_sensor_bound(void)
{
	struct acpi_device *adev;
	bool bound = false;
	unsigned int link;

	for_each_acpi_dev_match(adev, "OVTI02C1", NULL, -1) {
		struct device *pdev = acpi_get_first_physical_node(adev);

		if (pdev) {
			if (pdev->driver)
				bound = true;
			put_device(pdev);
		}

		for (link = 0; link < 8 && !bound; link++) {
			const struct software_node *node;
			struct i2c_client *client;
			char name[ACPI_ID_LEN + 4];

			snprintf(name, sizeof(name), "OVTI02C1-%u", link);
			node = software_node_find_by_name(NULL, name);
			if (!node)
				continue;
			client = i2c_find_device_by_fwnode(
				software_node_fwnode(node));
			if (client) {
				if (client->dev.driver)
					bound = true;
				put_device(&client->dev);
			}
			break;
		}
	}
	return bound;
}

static void ipu_bridge_schedule_sensor_retries(void)
{
	mod_delayed_work(system_wq, &ipu_bridge_sensor_dwork,
			 msecs_to_jiffies(500));
}

static void ipu_bridge_sensor_retry(struct work_struct *work)
{
	static int pass;

	pr_err("ipu_bridge: delayed sensor re-probe (pass %d)\n", pass + 1);
	ipu_bridge_reattach_sensor_swnodes();
	if (ipu_bridge_sensor_bound()) {
		pr_err("ipu_bridge: ov02c10 bound after delay\n");
		pass = 0;
		return;
	}
	if (pass++ < 5) {
		schedule_delayed_work(&ipu_bridge_sensor_dwork,
				      msecs_to_jiffies(1000));
	} else {
		pr_err("ipu_bridge: ov02c10 still unbound after retries\n");
		pass = 0;
	}
}

static int ipu_bridge_reattach_ivsc_fwnodes(void)
{
	struct device *csi_dev;
	int ret;

	pr_err("ipu_bridge: reattach IVSC swnode to mei-csi\n");

	csi_dev = ipu_bridge_find_mei_csi();
	if (!csi_dev) {
		pr_err("ipu_bridge: reattach: mei-csi device not found yet\n");
		return -ENODEV;
	}

	ret = ipu_bridge_attach_swnode(csi_dev);
	put_device(csi_dev);
	return ret;
}

static void ipu_bridge_deferred_reattach(struct work_struct *work);
static DECLARE_DELAYED_WORK(ipu_bridge_reattach_dwork,
			    ipu_bridge_deferred_reattach);

static void ipu_bridge_deferred_reattach(struct work_struct *work)
{
	struct device *csi_dev;
	static int pass;
	int ret;

	pr_err("ipu_bridge: deferred reattach+rebind (pass %d)\n", pass + 1);

	csi_dev = ipu_bridge_find_mei_csi();
	if (!csi_dev) {
		pr_err("ipu_bridge: deferred: mei-csi still missing\n");
		goto again;
	}

	ret = ipu_bridge_attach_swnode(csi_dev);
	if (ret) {
		put_device(csi_dev);
		goto again;
	}

	if (csi_dev->driver) {
		pr_err("ipu_bridge: deferred: %s already bound\n",
		       dev_name(csi_dev));
		put_device(csi_dev);
		ipu_bridge_reattach_sensor_swnodes();
		ipu_bridge_schedule_sensor_retries();
		pass = 0;
		return;
	}

	pr_err("ipu_bridge: deferred: device_attach %s\n",
	       dev_name(csi_dev));
	ret = device_attach(csi_dev);
	pr_err("ipu_bridge: deferred: device_attach -> %d\n", ret);
	put_device(csi_dev);
	if (ret == 1) {
		ipu_bridge_reattach_sensor_swnodes();
		ipu_bridge_schedule_sensor_retries();
		pass = 0;
		return;
	}

again:
	if (pass++ < 1) {
		schedule_delayed_work(&ipu_bridge_reattach_dwork,
				      msecs_to_jiffies(450));
	} else {
		pass = 0;
	}
}

static void ipu_bridge_schedule_reattach(void)
{
	mod_delayed_work(system_wq, &ipu_bridge_reattach_dwork,
			 msecs_to_jiffies(50));
}

/*
 * v1.9 restored OVTI02C1-N as ACPI fwnode secondary so the post-S4 LJCA
 * i2c client has a graph endpoint (check_hwcfg). On the *next* S4,
 * usb_dev_restore → ljca_disconnect → acpi_dev_pm_detach →
 * sysfs_unmerge_group NULL kernfs (0x8).
 *
 * v1.10 NULLed secondary; v1.11 unbound; v1.12/1.13 recreate-on-resume
 * with fwnode; v1.14/1.15 freeze-unregister. S4 #1 camera recovery then
 * worked but S4 #2 still died: any post-S4 client with ACPI
 * primary->secondary set Oopses on teardown.
 *
 * v1.16 instantiates a non-ACPI swnode i2c client. Unregister that
 * (no acpi_dev_pm_detach) and also drop a leftover ACPI physical node.
 */
static void ipu_bridge_destroy_sensor_i2c_clients(void)
{
	struct acpi_device *adev;
	unsigned int i, link;

	for (i = 0; i < ARRAY_SIZE(ipu_supported_sensors); i++) {
		const struct ipu_sensor_config *cfg =
			&ipu_supported_sensors[i];

		for_each_acpi_dev_match(adev, cfg->hid, NULL, -1) {
			struct i2c_client *client;
			const struct software_node *node;
			struct fwnode_handle *swnode_fw;
			char name[ACPI_ID_LEN + 4];

			if (!ACPI_PTR(adev->status.enabled))
				continue;

			/*
			 * Cold-boot client is the ACPI physical node (and
			 * has OVTI02C1-N as secondary). Unregister it and
			 * do not walk the swnode — find would be the same
			 * dying device. Post-S4 there is no ACPI i2c
			 * client; unregister the swnode client via
			 * i2c_find_device_by_fwnode (that get is extra;
			 * put it before unregister — proven on v1.16 S4 #2).
			 */
			if (ipu_bridge_unregister_acpi_i2c(adev, NULL, NULL))
				continue;

			for (link = 0; link < 8; link++) {
				snprintf(name, sizeof(name), "%s-%u",
					 cfg->hid, link);
				node = software_node_find_by_name(NULL, name);
				if (!node)
					continue;
				swnode_fw = software_node_fwnode(node);
				client = i2c_find_device_by_fwnode(swnode_fw);
				if (client) {
					pr_err("ipu_bridge: unregister swnode i2c %s before S4\n",
					       dev_name(&client->dev));
					put_device(&client->dev);
					i2c_unregister_device(client);
				}
				break;
			}
		}
	}
}

static void ipu_bridge_clear_sensor_acpi_secondary(void)
{
	struct acpi_device *adev;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(ipu_supported_sensors); i++) {
		const struct ipu_sensor_config *cfg =
			&ipu_supported_sensors[i];

		for_each_acpi_dev_match(adev, cfg->hid, NULL, -1) {
			struct fwnode_handle *primary;

			if (!ACPI_PTR(adev->status.enabled))
				continue;
			primary = acpi_fwnode_handle(adev);
			if (!primary || !primary->secondary ||
			    IS_ERR(primary->secondary))
				continue;
			pr_err("ipu_bridge: clearing ACPI secondary on %s before S4\n",
			       acpi_dev_name(adev));
			primary->secondary = NULL;
		}
	}
}

static int ipu_bridge_pm_notify(struct notifier_block *nb,
				unsigned long mode, void *unused)
{
	switch (mode) {
	case PM_HIBERNATION_PREPARE:
		cancel_delayed_work_sync(&ipu_bridge_reattach_dwork);
		cancel_delayed_work_sync(&ipu_bridge_sensor_dwork);
		ipu_bridge_destroy_sensor_i2c_clients();
		ipu_bridge_clear_sensor_acpi_secondary();
		break;
	default:
		break;
	}
	return NOTIFY_DONE;
}

static struct notifier_block ipu_bridge_pm_nb = {
	.notifier_call = ipu_bridge_pm_notify,
};

static void ipu_bridge_ensure_pm_notifier(void)
{
	static bool registered;

	if (registered)
		return;
	register_pm_notifier(&ipu_bridge_pm_nb);
	registered = true;
}

int ipu_bridge_init(struct device *dev,
		    ipu_parse_sensor_fwnode_t parse_sensor_fwnode)
{
	struct fwnode_handle *fwnode;
	struct ipu_bridge *bridge;
	unsigned int i;
	int ret;

	guard(mutex)(&ipu_bridge_mutex);

	ipu_bridge_ensure_pm_notifier();

	if (!ipu_bridge_check_fwnode_graph(dev_fwnode(dev))) {
		struct device *csi_dev = ipu_bridge_find_mei_csi();
		bool csi_needs_s4 = true;

		/*
		 * Graph already exists: normal on cold boot (isys/psys each
		 * call ipu_bridge_init) and after S4 (IPU memory restored).
		 * v1.8 always scheduled S4 reattach here. On cold boot CSI
		 * is already bound with a fwnode; poking ov02c10 then races
		 * isys runtime PM → NULL power_lock oops, PSYS never binds
		 * (2026-09-05 01:31). S4 recreates mei-csi *without* a
		 * secondary swnode — only then recover.
		 */
		if (csi_dev) {
			if (dev_fwnode(csi_dev) && csi_dev->driver)
				csi_needs_s4 = false;
			put_device(csi_dev);
		}
		if (csi_needs_s4) {
			ipu_bridge_reattach_ivsc_fwnodes();
			ipu_bridge_schedule_reattach();
		}
		return 0;
	}

	if (!ipu_bridge_ivsc_is_ready())
		return dev_err_probe(dev, -EPROBE_DEFER,
				     "waiting for IVSC to become ready\n");

	bridge = kzalloc_obj(*bridge);
	if (!bridge)
		return -ENOMEM;

	strscpy(bridge->ipu_node_name, IPU_HID,
		sizeof(bridge->ipu_node_name));
	bridge->ipu_hid_node.name = bridge->ipu_node_name;
	bridge->dev = dev;
	bridge->parse_sensor_fwnode = parse_sensor_fwnode;

	ret = software_node_register(&bridge->ipu_hid_node);
	if (ret < 0) {
		dev_err(dev, "Failed to register the IPU HID node\n");
		goto err_free_bridge;
	}

	/*
	 * Map the lane arrangement, which is fixed for the IPU3 (meaning we
	 * only need one, rather than one per sensor). We include it as a
	 * member of the struct ipu_bridge rather than a global variable so
	 * that it survives if the module is unloaded along with the rest of
	 * the struct.
	 */
	for (i = 0; i < IPU_MAX_LANES; i++)
		bridge->data_lanes[i] = i + 1;

	ret = ipu_bridge_connect_sensors(bridge);
	if (ret || bridge->n_sensors == 0)
		goto err_unregister_ipu;

	dev_info(dev, "Connected %d cameras\n", bridge->n_sensors);

	fwnode = software_node_fwnode(&bridge->ipu_hid_node);
	if (!fwnode) {
		dev_err(dev, "Error getting fwnode from ipu software_node\n");
		ret = -ENODEV;
		goto err_unregister_sensors;
	}

	set_secondary_fwnode(dev, fwnode);

	return 0;

err_unregister_sensors:
	ipu_bridge_unregister_sensors(bridge);
err_unregister_ipu:
	software_node_unregister(&bridge->ipu_hid_node);
err_free_bridge:
	kfree(bridge);

	return ret;
}
EXPORT_SYMBOL_NS_GPL(ipu_bridge_init, "INTEL_IPU_BRIDGE");

static void __exit ipu_bridge_exit(void)
{
	unregister_pm_notifier(&ipu_bridge_pm_nb);
	cancel_delayed_work_sync(&ipu_bridge_reattach_dwork);
	cancel_delayed_work_sync(&ipu_bridge_sensor_dwork);
}
module_exit(ipu_bridge_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Intel IPU Sensors Bridge driver");
